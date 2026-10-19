// bench/next_bench.zig
// Measures streaming, control dispatch, and allocator costs over real pipes.
// Arguments: delta count (20000), workload (normal), repetitions (1).

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("agent");

const default_lines: usize = 20_000;

const delta_text = "The quick brown fox jumps over the lazy dog, and then keeps running for a while longer than expected.";

// Counts successful backing allocations and growth; transcript/timing storage
// belongs to the harness and is excluded.
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

/// Temporary transcript and streaming stub; `deinit` removes both.
const Stub = struct {
    parent: std.Io.Dir,
    dir: std.Io.Dir,
    sub_path: [sub_path_len]u8,
    path: [:0]u8,

    const random_bytes_count = 12;
    const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

    fn init(gpa: std.mem.Allocator, io: std.Io, lines: usize, workload: Workload) !Stub {
        var random_bytes: [random_bytes_count]u8 = undefined;
        io.random(&random_bytes);
        var sub_path: [sub_path_len]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);

        var parent = try std.Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/bench", .{});
        errdefer parent.close(io);
        var dir = try parent.createDirPathOpen(io, &sub_path, .{});
        errdefer dir.close(io);

        var transcript: std.Io.Writer.Allocating = .init(gpa);
        defer transcript.deinit();
        const out = &transcript.writer;
        if (workload == .control) try out.writeAll("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"zig_1\",\"response\":{}}}\n");
        try out.writeAll("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"bench\"}\n");
        const text = try workload.text(gpa);
        defer gpa.free(text);
        if (workload == .recovery) {
            const oversized = try gpa.alloc(u8, 2 * 1024 * 1024);
            defer gpa.free(oversized);
            @memset(oversized, 'x');
            try writeDelta(out, oversized, 0);
        }
        for (0..lines) |i| {
            if (workload == .control) {
                var id_buffer: [32]u8 = undefined;
                const request_id = try std.fmt.bufPrint(&id_buffer, "bench_{d}", .{i});
                try std.json.Stringify.value(.{
                    .type = "control_request",
                    .request_id = request_id,
                    .request = .{
                        .subtype = "mcp_message",
                        .server_name = "bench",
                        .message = .{
                            .jsonrpc = "2.0",
                            .method = "tools/call",
                            .id = i,
                            .params = .{ .name = "ping", .arguments = .{ .value = i } },
                        },
                    },
                }, .{}, out);
                try out.writeByte('\n');
            }
            try writeDelta(out, text, i);
        }
        try out.writeAll("{\"type\":\"result\",\"result\":\"done\"}\n");
        try dir.writeFile(io, .{ .sub_path = "transcript.jsonl", .data = transcript.written() });

        // Drain control replies concurrently; result closes stdin and releases
        // the drain process's inherited stdout descriptor.
        const script =
            \\#!/bin/sh
            \\cat <&0 >/dev/null &
            \\exec cat "$(dirname "$0")/transcript.jsonl"
            \\
        ;
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

const Workload = enum {
    normal,
    escaped,
    large,
    control,
    recovery,

    fn text(self: Workload, gpa: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .normal, .control, .recovery => gpa.dupe(u8, delta_text),
            .escaped => gpa.dupe(u8, "quoted \"text\", backslash \\, newline\n, tab\t and control \x01 "),
            .large => blk: {
                const bytes = try gpa.alloc(u8, 8192);
                @memset(bytes, 'x');
                break :blk bytes;
            },
        };
    }
};

fn writeDelta(out: *std.Io.Writer, text: []const u8, index: usize) !void {
    try out.writeAll("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":");
    try std.json.Stringify.value(text, .{}, out);
    try out.print("}}}},\"session_id\":\"bench\",\"uuid\":\"{d}\"}}\n", .{index});
}

fn percentile(sorted: []const u64, percent: usize) u64 {
    return sorted[@min(sorted.len - 1, (sorted.len * percent + 99) / 100 - 1)];
}

fn controlTool(context: ?*anyopaque, _: std.mem.Allocator, _: std.json.Value) !agent.ToolResult {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    return .{ .text = "ok" };
}

fn measure(init: std.process.Init, out: *std.Io.Writer, stub: *Stub, lines: usize, workload: Workload, repetition: usize) !void {
    var counting: CountingAllocator = .{ .child = init.gpa };
    var control_calls: usize = 0;
    const tools = [_]agent.Tool{.{
        .name = "ping",
        .description = "Benchmark dispatch",
        .input_schema = "{\"type\":\"object\"}",
        .handler = controlTool,
        .context = @ptrCast(&control_calls),
    }};
    const servers = [_]agent.McpServer{.{ .name = "bench", .tools = &tools }};
    const client = try agent.Client.open(counting.allocator(), init.io, .{
        .claude_path = stub.path,
        .sdk_mcp_servers = if (workload == .control) &servers else &.{},
    });
    var closed = false;
    defer if (!closed) {
        _ = client.close();
    };

    // Consume the ready event before timing; process startup is not a latency
    // sample. Every subsequent event retains its normal owned lifetime.
    var ready = (try client.next()) orelse return error.MissingReadyEvent;
    ready.deinit();
    const bytes_before = counting.allocated_bytes;
    const allocations_before = counting.allocations;
    counting.peak_live_bytes = counting.live_bytes;
    const expected_deltas = lines + @intFromBool(workload == .recovery);
    const latencies = try init.gpa.alloc(u64, expected_deltas + 1);
    defer init.gpa.free(latencies);

    var events: usize = 0;
    var deltas: usize = 0;
    var delta_bytes: usize = 0;
    const started = std.Io.Clock.Timestamp.now(init.io, .awake);
    while (true) {
        const event_started = std.Io.Clock.Timestamp.now(init.io, .awake);
        var event = (try client.next()) orelse break;
        if (event.textDelta()) |text| {
            deltas += 1;
            delta_bytes += text.len;
        }
        if (event.kind == .result) client.closeStdin();
        event.deinit();
        if (events == latencies.len) return error.EventCountMismatch;
        latencies[events] = @intCast(event_started.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.toNanoseconds());
        events += 1;
    }
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake));
    const term = try client.wait();
    if (term != .exited or term.exited != 0) return error.StubFailed;
    if (deltas != expected_deltas or events != latencies.len) return error.EventCountMismatch;
    if (control_calls != (if (workload == .control) lines else @as(usize, 0))) return error.ControlCountMismatch;

    const loop_bytes = counting.allocated_bytes - bytes_before;
    const loop_allocations = counting.allocations - allocations_before;
    const peak = counting.peak_live_bytes;
    const retained = counting.live_bytes;
    _ = client.close();
    closed = true;
    if (counting.live_bytes != 0) return error.ClientAllocationLeak;
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));
    const ns: f64 = @floatFromInt(elapsed.raw.toNanoseconds());
    const count: f64 = @floatFromInt(events);
    try out.print(
        "{{\"benchmark_schema\":1,\"zig_version\":\"{s}\",\"optimize\":\"{s}\",\"target\":\"{s}\",\"workload\":\"{t}\",\"run\":{d},\"events\":{d},\"controls\":{d},\"delta_bytes\":{d},\"events_per_second\":{d:.1},\"ns_per_event\":{d:.1},\"latency_p50_ns\":{d},\"latency_p95_ns\":{d},\"latency_p99_ns\":{d},\"latency_max_ns\":{d},\"allocated_bytes_per_event\":{d:.2},\"allocations_per_event\":{d:.3},\"peak_sdk_bytes\":{d},\"retained_sdk_bytes\":{d},\"after_close_sdk_bytes\":{d}}}\n",
        .{ builtin.zig_version_string, @tagName(builtin.mode), @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi), workload, repetition, events, control_calls, delta_bytes, count * std.time.ns_per_s / ns, ns / count, percentile(latencies, 50), percentile(latencies, 95), percentile(latencies, 99), latencies[latencies.len - 1], @as(f64, @floatFromInt(loop_bytes)) / count, @as(f64, @floatFromInt(loop_allocations)) / count, peak, retained, counting.live_bytes },
    );
    try out.flush();
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const lines = if (args.next()) |arg| try std.fmt.parseInt(usize, arg, 10) else default_lines;
    const workload_name = args.next() orelse "normal";
    const repetitions = if (args.next()) |arg| try std.fmt.parseInt(usize, arg, 10) else 1;
    if (lines == 0 or repetitions == 0 or args.next() != null) return error.InvalidArguments;
    const all = std.mem.eql(u8, workload_name, "all");
    const selected = if (all) Workload.normal else std.meta.stringToEnum(Workload, workload_name) orelse return error.InvalidWorkload;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    inline for (std.meta.tags(Workload)) |workload| {
        if (all or selected == workload) {
            var stub = try Stub.init(init.gpa, init.io, lines, workload);
            defer stub.deinit(init.gpa, init.io);
            for (0..repetitions) |i| try measure(init, &stdout.interface, &stub, lines, workload, i + 1);
        }
    }
}
