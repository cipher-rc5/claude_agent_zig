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
    const a = numberOf(obj.get("a")) orelse return .{ .text = "missing a", .is_error = true };
    const b = numberOf(obj.get("b")) orelse return .{ .text = "missing b", .is_error = true };
    return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{a + b}) };
}

fn numberOf(value: ?std.json.Value) ?f64 {
    return switch (value orelse return null) {
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
}
