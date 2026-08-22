// src/demo_tools.zig
// The in-process tools the demo client exposes to the agent.

const std = @import("std");
const agent = @import("agent.zig");

/// Reads from the host process's environment, reached through the context
/// pointer rather than a global.
fn hostEnv(context: ?*anyopaque, arena: std.mem.Allocator, arguments: std.json.Value) !agent.ToolResult {
    const environ: *const std.process.Environ.Map = @ptrCast(@alignCast(context.?));
    const obj = switch (arguments) {
        .object => |o| o,
        else => return .{ .text = "expected an object", .is_error = true },
    };
    const name = switch (obj.get("name") orelse return .{ .text = "missing name", .is_error = true }) {
        .string => |v| v,
        else => return .{ .text = "name must be a string", .is_error = true },
    };
    const value = environ.get(name) orelse return .{ .text = "not set", .is_error = true };
    return .{ .text = try arena.dupe(u8, value) };
}

fn addNumbers(_: ?*anyopaque, arena: std.mem.Allocator, arguments: std.json.Value) !agent.ToolResult {
    const obj = switch (arguments) {
        .object => |o| o,
        else => return .{ .text = "expected an object", .is_error = true },
    };
    const a = obj.get("a") orelse return .{ .text = "missing a", .is_error = true };
    const b = obj.get("b") orelse return .{ .text = "missing b", .is_error = true };

    // Two integers add exactly, so they never go through f64. Above 2^53 that
    // conversion is lossy, and 9007199254740993 would come back as
    // 9007199254740992. Only a float operand forces the float path.
    if (a == .integer and b == .integer) {
        const sum = std.math.add(i64, a.integer, b.integer) catch
            return .{ .text = "sum out of range", .is_error = true };
        return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{sum}) };
    }

    const x = numberOf(a) orelse return .{ .text = "a must be a number", .is_error = true };
    const y = numberOf(b) orelse return .{ .text = "b must be a number", .is_error = true };
    return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{x + y}) };
}

fn numberOf(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

pub fn build(environ: *const std.process.Environ.Map) [2]agent.Tool {
    return .{
        .{
            .name = "host_env",
            .description = "Read an environment variable from the host process.",
            .input_schema =
            \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
            ,
            .handler = hostEnv,
            .context = @ptrCast(@constCast(environ)),
        },
        // The handler adds two integers exactly, but `"type":"number"` is the
        // limit of what that buys end to end: the model serializes a JSON
        // number as an IEEE 754 double, so an argument above 2^53 is already
        // rounded by the time it reaches the wire. Exactness past that point
        // needs a string or integer-typed parameter, which is a schema
        // decision rather than a handler one.
        .{
            .name = "add",
            .description = "Add two numbers.",
            .input_schema =
            \\{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}},"required":["a","b"]}
            ,
            .handler = addNumbers,
        },
    };
}

test "add handles integers, floats and bad input" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"a\":17,\"b\":25.5}", .{});
    const ok = try addNumbers(null, a, parsed.value);
    try std.testing.expectEqualStrings("42.5", ok.text);
    try std.testing.expect(!ok.is_error);

    const missing = try std.json.parseFromSlice(std.json.Value, a, "{\"a\":1}", .{});
    try std.testing.expect((try addNumbers(null, a, missing.value)).is_error);

    // A non-object argument is a caller error, reported back rather than fatal.
    try std.testing.expect((try addNumbers(null, a, .{ .integer = 3 })).is_error);

    // A non-numeric operand is reported rather than treated as missing.
    const stringy = try std.json.parseFromSlice(std.json.Value, a, "{\"a\":1,\"b\":\"x\"}", .{});
    try std.testing.expect((try addNumbers(null, a, stringy.value)).is_error);
}

test "integer addition stays exact past the f64 mantissa" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 2^53 + 1 is the first integer f64 cannot represent, so a float round
    // trip would answer 9007199254740992 here.
    const big = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"a\":9007199254740993,\"b\":0}",
        .{},
    );
    try std.testing.expectEqualStrings("9007199254740993", (try addNumbers(null, a, big.value)).text);

    // A float operand still opts into float arithmetic.
    const mixed = try std.json.parseFromSlice(std.json.Value, a, "{\"a\":2,\"b\":0.5}", .{});
    try std.testing.expectEqualStrings("2.5", (try addNumbers(null, a, mixed.value)).text);

    // Overflow is a reported error, not a wrap.
    const overflow = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"a\":9223372036854775807,\"b\":1}",
        .{},
    );
    try std.testing.expect((try addNumbers(null, a, overflow.value)).is_error);
}
