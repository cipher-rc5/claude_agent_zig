// examples/demo_tools.zig
// The in-process tools the demo client exposes to the agent.

const std = @import("std");
const agent = @import("agent");

// Allowlist prevents model-selected names from exposing inherited credentials.
const readable_env = [_][]const u8{
    "HOME",
    "LANG",
    "PATH",
    "PWD",
    "SHELL",
    "TERM",
    "USER",
};

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

    // Check before lookup so refusals cannot reveal whether a secret is set.
    if (!isReadable(name)) return .{ .text = "not a readable variable", .is_error = true };

    const value = environ.get(name) orelse return .{ .text = "not set", .is_error = true };
    return .{ .text = try arena.dupe(u8, value) };
}

fn isReadable(name: []const u8) bool {
    for (readable_env) |allowed| {
        if (std.mem.eql(u8, allowed, name)) return true;
    }
    return false;
}

// Integer pairs use exact i64 arithmetic; decimal strings avoid CLI rounding above 2^53.
fn addNumbers(_: ?*anyopaque, arena: std.mem.Allocator, arguments: std.json.Value) !agent.ToolResult {
    const obj = switch (arguments) {
        .object => |o| o,
        else => return .{ .text = "expected an object", .is_error = true },
    };
    const a = operandOf(obj.get("a") orelse return .{ .text = "missing a", .is_error = true });
    const b = operandOf(obj.get("b") orelse return .{ .text = "missing b", .is_error = true });

    switch (a) {
        .invalid => return .{ .text = "a must be a number in decimal", .is_error = true },
        .out_of_range => return .{ .text = "a is out of range", .is_error = true },
        else => {},
    }
    switch (b) {
        .invalid => return .{ .text = "b must be a number in decimal", .is_error = true },
        .out_of_range => return .{ .text = "b is out of range", .is_error = true },
        else => {},
    }

    if (a == .integer and b == .integer) {
        const sum = std.math.add(i64, a.integer, b.integer) catch
            return .{ .text = "sum out of range", .is_error = true };
        return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{sum}) };
    }

    // Use f128 so mixed arithmetic preserves i64 operands above 2^53.
    const sum = a.wide() + b.wide();
    if (!inF64Range(sum)) return .{ .text = "sum out of range", .is_error = true };
    return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{sum}) };
}

// Distinguish integer overflow so it never falls back to floats.
const Operand = union(enum) {
    integer: i64,
    float: f128,
    out_of_range,
    invalid,

    // Explicit rejected variants keep this exhaustive.
    fn wide(self: Operand) f128 {
        return switch (self) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            .out_of_range, .invalid => unreachable,
        };
    }
};

fn operandOf(value: std.json.Value) Operand {
    return switch (value) {
        .integer => |i| .{ .integer = i },
        .float => |f| if (std.math.isFinite(f)) .{ .float = f } else .out_of_range,
        .string => |s| parseDecimal(s),
        else => .invalid,
    };
}

// `parseFloat` also accepts non-decimal and non-finite input; validate first.
fn parseDecimal(s: []const u8) Operand {
    if (!isDecimal(s)) return .invalid;
    if (std.fmt.parseInt(i64, s, 10)) |i| {
        return .{ .integer = i };
    } else |err| switch (err) {
        // Float fallback would silently lose integer precision.
        error.Overflow => return .out_of_range,
        error.InvalidCharacter => {},
    }
    const f = std.fmt.parseFloat(f128, s) catch return .invalid;
    return if (inF64Range(f)) .{ .float = f } else .out_of_range;
}

// Preserve f128 precision for mixed arithmetic within finite f64 range.
fn inF64Range(f: f128) bool {
    return std.math.isFinite(f) and @abs(f) <= std.math.floatMax(f64);
}

// Decimal grammar excludes the extensions accepted by `parseFloat`.
fn isDecimal(s: []const u8) bool {
    var rest = s;
    if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) rest = rest[1..];

    const int_digits = digitRun(rest);
    rest = rest[int_digits..];

    var frac_digits: usize = 0;
    if (rest.len > 0 and rest[0] == '.') {
        rest = rest[1..];
        frac_digits = digitRun(rest);
        rest = rest[frac_digits..];
    }
    if (int_digits == 0 and frac_digits == 0) return false;

    if (rest.len > 0 and (rest[0] == 'e' or rest[0] == 'E')) {
        rest = rest[1..];
        if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) rest = rest[1..];
        const exp_digits = digitRun(rest);
        if (exp_digits == 0) return false;
        rest = rest[exp_digits..];
    }
    return rest.len == 0;
}

fn digitRun(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and std.ascii.isDigit(s[n])) n += 1;
    return n;
}

// Demo-only: log to the stderr context and allow all calls; production must authorize.
pub fn logAndAllow(
    context: ?*anyopaque,
    _: std.mem.Allocator,
    tool_name: []const u8,
    input: std.json.Value,
) !agent.PermissionDecision {
    const log: *std.Io.Writer = @ptrCast(@alignCast(context.?));
    try log.print("[permission] {s} ", .{tool_name});
    try std.json.Stringify.value(input, .{}, log);
    try log.writeByte('\n');
    try log.flush();
    return .allow;
}

pub fn build(environ: *const std.process.Environ.Map) [2]agent.Tool {
    return .{
        .{
            .name = "host_env",
            .description = "Read one of a fixed set of non-secret environment " ++
                "variables from the host process: HOME, LANG, PATH, PWD, SHELL, " ++
                "TERM, USER. Any other name is refused.",
            // Schema hints do not replace handler enforcement.
            .input_schema =
            \\{"type":"object","properties":{"name":{"type":"string","enum":["HOME","LANG","PATH","PWD","SHELL","TERM","USER"]}},"required":["name"]}
            ,
            .handler = hostEnv,
            .context = @ptrCast(@constCast(environ)),
        },
        // JSON integers can lose precision during CLI serialization.
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

// Tests exercise private numeric and environment handlers.

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

    try std.testing.expect((try addNumbers(null, a, .{ .integer = 3 })).is_error);

    const stringy = try std.json.parseFromSlice(std.json.Value, a, "{\"a\":1,\"b\":\"x\"}", .{});
    try std.testing.expect((try addNumbers(null, a, stringy.value)).is_error);
}

test "decimal strings are the shape that survives the wire" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const exact = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"a\":\"9007199254740993\",\"b\":\"0\"}",
        .{},
    );
    try std.testing.expectEqualStrings("9007199254740993", (try addNumbers(null, a, exact.value)).text);

    const mixed = try std.json.parseFromSlice(std.json.Value, a, "{\"a\":\"17\",\"b\":25}", .{});
    try std.testing.expectEqualStrings("42", (try addNumbers(null, a, mixed.value)).text);

    const negative = try std.json.parseFromSlice(std.json.Value, a, "{\"a\":\"-5\",\"b\":\"2\"}", .{});
    try std.testing.expectEqualStrings("-3", (try addNumbers(null, a, negative.value)).text);

    const fractional = try std.json.parseFromSlice(std.json.Value, a, "{\"a\":\"2.5\",\"b\":\"0.5\"}", .{});
    try std.testing.expectEqualStrings("3", (try addNumbers(null, a, fractional.value)).text);

    const overflow = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"a\":\"9223372036854775807\",\"b\":\"1\"}",
        .{},
    );
    try std.testing.expect((try addNumbers(null, a, overflow.value)).is_error);
}

test "an integer too large for i64 is reported, not answered as a float" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{
        "{\"a\":\"9223372036854775808\",\"b\":\"1\"}",
        "{\"a\":\"99999999999999999999999999\",\"b\":\"1\"}",
        "{\"a\":\"1\",\"b\":\"-9223372036854775809\"}",
    }) |input| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, input, .{});
        const result = try addNumbers(null, a, parsed.value);
        try std.testing.expect(result.is_error);
    }
}

test "each operand keeps its own exactness" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mixed = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"a\":\"0.5\",\"b\":\"9007199254740993\"}",
        .{},
    );
    const result = try addNumbers(null, a, mixed.value);
    try std.testing.expectEqualStrings("9007199254740993.5", result.text);
    try std.testing.expect(!result.is_error);

    const swapped = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"a\":\"9007199254740993\",\"b\":\"0.5\"}",
        .{},
    );
    try std.testing.expectEqualStrings("9007199254740993.5", (try addNumbers(null, a, swapped.value)).text);
}

test "the handler honours its own schema" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{
        "{\"a\":\"inf\",\"b\":\"1\"}",
        "{\"a\":\"-inf\",\"b\":\"1\"}",
        "{\"a\":\"nan\",\"b\":\"1\"}",
        "{\"a\":\"1e400\",\"b\":\"1\"}",
        "{\"a\":1e308,\"b\":1e308}",
        "{\"a\":\"0x10\",\"b\":\"0x10\"}",
        "{\"a\":\"1_000\",\"b\":\"0\"}",
        "{\"a\":\"0b101\",\"b\":\"1\"}",
        "{\"a\":\"0o17\",\"b\":\"1\"}",
        "{\"a\":\"\",\"b\":\"1\"}",
        "{\"a\":\" 5\",\"b\":\"1\"}",
        "{\"a\":\"5 \",\"b\":\"1\"}",
        "{\"a\":\".\",\"b\":\"1\"}",
        "{\"a\":\"1e\",\"b\":\"1\"}",
        "{\"a\":true,\"b\":1}",
        "{\"a\":null,\"b\":1}",
    }) |input| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, input, .{});
        const result = try addNumbers(null, a, parsed.value);
        try std.testing.expect(result.is_error);
    }

    for ([_][2][]const u8{
        .{ "{\"a\":\"1e10\",\"b\":\"0\"}", "10000000000" },
        .{ "{\"a\":\"+5\",\"b\":\"1\"}", "6" },
        .{ "{\"a\":\".5\",\"b\":\"0\"}", "0.5" },
        .{ "{\"a\":\"5.\",\"b\":\"0\"}", "5" },
        .{ "{\"a\":\"1.5e2\",\"b\":\"0\"}", "150" },
        .{ "{\"a\":\"-2.5E1\",\"b\":\"0\"}", "-25" },
    }) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, case[0], .{});
        const result = try addNumbers(null, a, parsed.value);
        try std.testing.expect(!result.is_error);
        try std.testing.expectEqualStrings(case[1], result.text);
    }
}

test "integer addition stays exact past the f64 mantissa" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const big = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"a\":9007199254740993,\"b\":0}",
        .{},
    );
    try std.testing.expectEqualStrings("9007199254740993", (try addNumbers(null, a, big.value)).text);

    const mixed = try std.json.parseFromSlice(std.json.Value, a, "{\"a\":2,\"b\":0.5}", .{});
    try std.testing.expectEqualStrings("2.5", (try addNumbers(null, a, mixed.value)).text);

    const overflow = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"a\":9223372036854775807,\"b\":1}",
        .{},
    );
    try std.testing.expect((try addNumbers(null, a, overflow.value)).is_error);
}

test "host_env answers only for the allowlisted names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ: std.process.Environ.Map = .init(a);
    defer environ.deinit();
    try environ.put("HOME", "/home/demo");
    try environ.put("AWS_SECRET_ACCESS_KEY", "sk-must-not-leak");

    const ctx: ?*anyopaque = @ptrCast(@constCast(&environ));

    const allowed = try std.json.parseFromSlice(std.json.Value, a, "{\"name\":\"HOME\"}", .{});
    const ok = try hostEnv(ctx, a, allowed.value);
    try std.testing.expect(!ok.is_error);
    try std.testing.expectEqualStrings("/home/demo", ok.text);

    const secret = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"name\":\"AWS_SECRET_ACCESS_KEY\"}",
        .{},
    );
    const refused = try hostEnv(ctx, a, secret.value);
    try std.testing.expect(refused.is_error);
    try std.testing.expect(std.mem.indexOf(u8, refused.text, "sk-must-not-leak") == null);

    const unset = try std.json.parseFromSlice(std.json.Value, a, "{\"name\":\"TERM\"}", .{});
    try std.testing.expectEqualStrings("not set", (try hostEnv(ctx, a, unset.value)).text);
    const absent = try std.json.parseFromSlice(std.json.Value, a, "{\"name\":\"NOPE\"}", .{});
    try std.testing.expectEqualStrings(
        "not a readable variable",
        (try hostEnv(ctx, a, absent.value)).text,
    );
}

test "the permission hook logs the call and allows it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var log: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer log.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"command\":\"ls\"}", .{});
    const decision = try logAndAllow(@ptrCast(&log.writer), a, "Bash", parsed.value);
    try std.testing.expect(decision == .allow);
    try std.testing.expectEqualStrings("[permission] Bash {\"command\":\"ls\"}\n", log.written());
}
