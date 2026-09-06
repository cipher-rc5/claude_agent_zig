// bench/next_bench.zig
// Measures Client.next() over a synthetic stream_event transcript: events per
// second, and heap bytes allocated per event.
//
// The hot path in `next` parses every line into a full `std.json.Value` tree
// with `.alloc_always`, one arena per event. This is the number that puts a
// cost on that choice, so a change to the read loop has a baseline to be
// compared against. Run it under a release mode (`just bench`); a Debug
// figure measures the allocator's bookkeeping more than the parser.
//
// The transcript is produced by a shell stub written to a temp dir at
// runtime, the same way tests/integration_test.zig builds its stubs, and is
// read over a real pipe so the figure includes the read loop's own buffering.
// One argument, optional: the number of stream_event lines (default 20000).

const std = @import("std");
const agent = @import("agent");

const default_lines: usize = 20_000;

/// Padding that brings a delta line to roughly 200 bytes, the size of a
/// typical token delta once the CLI's envelope is around it.
const delta_text = "The quick brown fox jumps over the lazy dog, and then keeps running for a while longer than expected.";

/// Every allocation the client makes goes through here on its way to the
/// real allocator. Counts bytes rather than calls: the arena behind each
/// event grows in chunks, so the byte total is what tracks the parse tree's
/// real footprint.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocated_bytes: usize = 0,
    allocations: usize = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn account(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) self.allocated_bytes += new_len - old_len;
        self.live_bytes = self.live_bytes - old_len + new_len;
        if (self.live_bytes > self.peak_live_bytes) self.peak_live_bytes = self.live_bytes;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        self.account(0, len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.account(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.account(memory.len, new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.account(memory.len, 0);
    }
};

/// The transcript on disk plus the stub that streams it, in a temp dir under
/// .zig-cache like the test suite's stubs. `deinit` removes the directory.
const Stub = struct {
    parent: std.Io.Dir,
    dir: std.Io.Dir,
    sub_path: [sub_path_len]u8,
    path: [:0]u8,

    const random_bytes_count = 12;
    const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

    fn init(gpa: std.mem.Allocator, io: std.Io, lines: usize) !Stub {
        var random_bytes: [random_bytes_count]u8 = undefined;
        io.random(&random_bytes);
        var sub_path: [sub_path_len]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);

        var parent = try std.Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/bench", .{});
        errdefer parent.close(io);
        var dir = try parent.createDirPathOpen(io, &sub_path, .{});
        errdefer dir.close(io);

        var transcript: std.ArrayList(u8) = .empty;
        defer transcript.deinit(gpa);
        try transcript.appendSlice(gpa, "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"bench\"}\n");
        for (0..lines) |i| {
            try transcript.print(
                gpa,
                "{{\"type\":\"stream_event\",\"event\":{{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}},\"session_id\":\"bench\",\"parent_tool_use_id\":null,\"uuid\":\"{x:0>8}\"}}\n",
                .{ delta_text, i },
            );
        }
        try transcript.appendSlice(gpa, "{\"type\":\"result\",\"result\":\"done\"}\n");
        try dir.writeFile(io, .{ .sub_path = "transcript.jsonl", .data = transcript.items });

        // `cat` rather than a printf loop so the producer is not the bottleneck
        // being measured. `trap '' PIPE` keeps the stub's exit its own if the
        // client closes stdin first, as in the integration tests.
        const transcript_path = try dir.realPathFileAlloc(io, "transcript.jsonl", gpa);
        defer gpa.free(transcript_path);
        const script = try std.fmt.allocPrint(gpa, "#!/bin/sh\ntrap '' PIPE\nexec cat '{s}'\n", .{transcript_path});
        defer gpa.free(script);
        try dir.writeFile(io, .{
            .sub_path = "stub.sh",
            .data = script,
            .flags = .{ .permissions = .executable_file },
        });

        return .{
            .parent = parent,
            .dir = dir,
            .sub_path = sub_path,
            .path = try dir.realPathFileAlloc(io, "stub.sh", gpa),
        };
    }

    fn deinit(stub: *Stub, gpa: std.mem.Allocator, io: std.Io) void {
        gpa.free(stub.path);
        stub.dir.close(io);
        stub.parent.deleteTree(io, &stub.sub_path) catch {};
        stub.parent.close(io);
        stub.* = undefined;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const lines: usize = if (args.next()) |arg| try std.fmt.parseInt(usize, arg, 10) else default_lines;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;

    var counting: CountingAllocator = .{ .child = init.gpa };
    const gpa = counting.allocator();

    var stub = try Stub.init(init.gpa, io, lines);
    defer stub.deinit(init.gpa, io);

    const client = try agent.Client.open(gpa, io, .{ .claude_path = stub.path });
    defer _ = client.close();

    // `open` allocates the client and its pipe buffers once; only what the
    // read loop adds on top is attributed to events.
    const bytes_before = counting.allocated_bytes;
    const allocations_before = counting.allocations;

    var events: usize = 0;
    var deltas: usize = 0;
    var delta_bytes: usize = 0;
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (try client.next()) |event| {
        var e = event;
        defer e.deinit();
        events += 1;
        // Read the delta the way a host would, so the accessor is inside the
        // measurement and the parse tree cannot be optimised away.
        if (e.textDelta()) |text| {
            deltas += 1;
            delta_bytes += text.len;
        }
    }
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake));

    const term = try client.wait();
    if (term != .exited or term.exited != 0) {
        try out.print("bench: stub exited abnormally: {any}\n", .{term});
        try out.flush();
        return error.StubFailed;
    }
    if (deltas != lines) {
        try out.print("bench: expected {d} text deltas, saw {d}\n", .{ lines, deltas });
        try out.flush();
        return error.EventCountMismatch;
    }

    const ns: f64 = @floatFromInt(elapsed.raw.toNanoseconds());
    const seconds = ns / std.time.ns_per_s;
    const loop_bytes = counting.allocated_bytes - bytes_before;
    const loop_allocations = counting.allocations - allocations_before;

    try out.print("next_bench: {d} events ({d} text deltas, {d} delta bytes) in {d:.3} s\n", .{ events, deltas, delta_bytes, seconds });
    try out.print("  events/s          {d:.0}\n", .{@as(f64, @floatFromInt(events)) / seconds});
    try out.print("  ns/event          {d:.0}\n", .{ns / @as(f64, @floatFromInt(events))});
    try out.print("  bytes/event       {d:.0}  ({d} bytes over the loop)\n", .{
        @as(f64, @floatFromInt(loop_bytes)) / @as(f64, @floatFromInt(events)),
        loop_bytes,
    });
    try out.print("  allocs/event      {d:.1}  ({d} calls over the loop)\n", .{
        @as(f64, @floatFromInt(loop_allocations)) / @as(f64, @floatFromInt(events)),
        loop_allocations,
    });
    try out.print("  peak live bytes   {d}\n", .{counting.peak_live_bytes});
    try out.flush();
}
