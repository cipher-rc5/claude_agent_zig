// examples/demo_tools.zig
// The in-process tools the demo client exposes to the agent.

const std = @import("std");
const agent = @import("agent");

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

/// Adds two operands, keeping integer arithmetic exact.
///
/// Exactness here is a property of the whole path, not just this function, and
/// the schema is the part that decides it. A JSON `number` is an IEEE 754
/// double on the way in, so an argument above 2^53 is already rounded before
/// any handler runs: asking for 9007199254740993 delivers ...992. Measured
/// against the CLI, `{"type":"integer"}` rounds identically — the loss happens
/// when the value is serialized, not when it is parsed. Only a decimal string
/// survives the round trip intact, which is why `a` and `b` are declared as
/// strings and parsed here.
///
/// Accepting JSON numbers as well keeps ordinary calls ergonomic; they simply
/// carry the usual double precision.
fn addNumbers(_: ?*anyopaque, arena: std.mem.Allocator, arguments: std.json.Value) !agent.ToolResult {
    const obj = switch (arguments) {
        .object => |o| o,
        else => return .{ .text = "expected an object", .is_error = true },
    };
    const a = obj.get("a") orelse return .{ .text = "missing a", .is_error = true };
    const b = obj.get("b") orelse return .{ .text = "missing b", .is_error = true };

    // Exact whenever both operands are integers, whichever way they arrived.
    if (integerOf(a)) |x| {
        if (integerOf(b)) |y| {
            const sum = std.math.add(i64, x, y) catch
                return .{ .text = "sum out of range", .is_error = true };
            return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{sum}) };
        }
    }

    const x = numberOf(a) orelse return .{ .text = "a must be a number", .is_error = true };
    const y = numberOf(b) orelse return .{ .text = "b must be a number", .is_error = true };
    return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{x + y}) };
}

/// The operand as an exact integer, whether it arrived as a JSON integer or as
/// a decimal string. A string that is not an integer (`"1.5"`, `"abc"`) is not
/// one, so it falls through to the float path.
fn integerOf(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |i| i,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// The operand as a float, for the cases integer arithmetic cannot cover.
/// Strings are accepted here too, so `"1.5"` behaves like `1.5`.
fn numberOf(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
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
        // Declared as strings on purpose. A JSON `number` argument is an IEEE
        // 754 double by the time it reaches the wire, so anything above 2^53
        // arrives already rounded no matter how exact the handler is — and
        // measuring against the CLI shows `{"type":"integer"}` rounds exactly
        // the same way. A decimal string is the only shape that survives, so
        // it is what the schema asks for, with the description telling the
        // model to send digits rather than a quoted float.
        .{
            .name = "add",
            .description = "Add two numbers. Send each as a decimal string so " ++
                "large integers stay exact.",
            .input_schema =
            \\{"type":"object","properties":{"a":{"type":"string","description":"a number in decimal, for example \"17\" or \"-2.5\""},"b":{"type":"string","description":"a number in decimal, for example \"25\""}},"required":["a","b"]}
            ,
            .handler = addNumbers,
        },
    };
}

// --- tests ---

// These stay here: they exercise `addNumbers`, which is private — the tool is
// reached by the agent through the handler pointer `build` installs, not by
// name. Moving them would mean making the handler public purely for test
// layout.

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

    // A string that is not a number at all is still reported. Numeric strings
    // are a supported shape; "x" is not one.
    const stringy = try std.json.parseFromSlice(std.json.Value, a, "{\"a\":1,\"b\":\"x\"}", .{});
    try std.testing.expect((try addNumbers(null, a, stringy.value)).is_error);
}

test "decimal strings are the shape that survives the wire" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The schema asks for strings because a JSON number is rounded to a double
    // before it ever reaches this process. Measured against the CLI, sending
    // 9007199254740993 as a number - or as a JSON integer - delivers ...992;
    // sent as a string it arrives whole, and this is the path that carries it.
    const exact = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"a\":\"9007199254740993\",\"b\":\"0\"}",
        .{},
    );
    try std.testing.expectEqualStrings("9007199254740993", (try addNumbers(null, a, exact.value)).text);

    // Mixing the two shapes still adds exactly.
    const mixed = try std.json.parseFromSlice(std.json.Value, a, "{\"a\":\"17\",\"b\":25}", .{});
    try std.testing.expectEqualStrings("42", (try addNumbers(null, a, mixed.value)).text);

    // A negative decimal string is an integer too.
    const negative = try std.json.parseFromSlice(std.json.Value, a, "{\"a\":\"-5\",\"b\":\"2\"}", .{});
    try std.testing.expectEqualStrings("-3", (try addNumbers(null, a, negative.value)).text);

    // A fractional string is not an integer, so it takes the float path.
    const fractional = try std.json.parseFromSlice(std.json.Value, a, "{\"a\":\"2.5\",\"b\":\"0.5\"}", .{});
    try std.testing.expectEqualStrings("3", (try addNumbers(null, a, fractional.value)).text);

    // Overflow is reported through the string path as well.
    const overflow = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"a\":\"9223372036854775807\",\"b\":\"1\"}",
        .{},
    );
    try std.testing.expect((try addNumbers(null, a, overflow.value)).is_error);
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
