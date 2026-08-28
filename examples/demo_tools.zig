// examples/demo_tools.zig
// The in-process tools the demo client exposes to the agent.

const std = @import("std");
const agent = @import("agent");

/// Names `host_env` will answer for. The allowlist is the point of the tool
/// rather than a detail of it.
///
/// A handler's arguments are model-influenced, and this process inherits its
/// parent's environment — which on a developer machine holds credentials. An
/// unrestricted version of this tool would hand those to the model on request.
/// The pattern to copy: name what a tool may reach, not what it may not.
const readable_env = [_][]const u8{
    "HOME",
    "LANG",
    "PATH",
    "PWD",
    "SHELL",
    "TERM",
    "USER",
};

/// Reads one of `readable_env` from the host process's environment, reached
/// through the context pointer rather than a global.
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

    // Refused before the lookup, so the reply cannot separate a set secret from
    // an unset one and confirm a name by which error comes back.
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

/// Adds two operands, keeping integer arithmetic exact.
///
/// A JSON `number` arrives as an IEEE 754 double, so an argument above 2^53 is
/// already rounded before any handler runs — and `{"type":"integer"}` rounds
/// identically, since the loss happens on serialization. Only a decimal string
/// survives intact, which is why `a` and `b` are declared as strings. JSON
/// numbers are still accepted, at the usual double precision.
///
/// Operands the schema does not promise are reported rather than guessed at:
/// an integer too large for `i64`, a non-decimal spelling like `"0x10"`, and
/// anything non-finite.
fn addNumbers(_: ?*anyopaque, arena: std.mem.Allocator, arguments: std.json.Value) !agent.ToolResult {
    const obj = switch (arguments) {
        .object => |o| o,
        else => return .{ .text = "expected an object", .is_error = true },
    };
    const a = operandOf(obj.get("a") orelse return .{ .text = "missing a", .is_error = true });
    const b = operandOf(obj.get("b") orelse return .{ .text = "missing b", .is_error = true });

    // Report the operand itself before reporting anything about the sum: an
    // out-of-range integer is a rejected input, not an arithmetic result.
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

    // Exact whenever both operands are integers, whichever way they arrived.
    if (a == .integer and b == .integer) {
        const sum = std.math.add(i64, a.integer, b.integer) catch
            return .{ .text = "sum out of range", .is_error = true };
        return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{sum}) };
    }

    // Mixed and fractional operands add in f128, which holds any `i64` and any
    // `f64` without rounding either one. Adding in f64 instead would discard
    // an integer operand's exactness the moment the other side was fractional:
    // 0.5 + 9007199254740993 answered ...992 rather than ...993.5.
    const sum = a.wide() + b.wide();
    if (!inF64Range(sum)) return .{ .text = "sum out of range", .is_error = true };
    return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{sum}) };
}

/// One classified operand. `out_of_range` stays distinct from `invalid`: a
/// well-formed integer that no longer fits is a range error worth naming, while
/// `"abc"` is not a number at all. Folding them lets `"9223372036854775808"`
/// reach the float path and come back as a wrong number.
const Operand = union(enum) {
    integer: i64,
    float: f128,
    out_of_range,
    invalid,

    /// The operand in the width the mixed path adds in.
    ///
    /// The rejected variants are named rather than folded into an `else`: both
    /// are unreachable today, but an `else` would silently swallow a variant
    /// added later and turn a rejected input into a panic. Naming them makes
    /// that a compile error instead.
    fn wide(self: Operand) f128 {
        return switch (self) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            .out_of_range, .invalid => unreachable,
        };
    }
};

/// Classifies one argument, whether it arrived as a JSON number or as the
/// decimal string the schema asks for.
fn operandOf(value: std.json.Value) Operand {
    return switch (value) {
        .integer => |i| .{ .integer = i },
        .float => |f| if (std.math.isFinite(f)) .{ .float = f } else .out_of_range,
        .string => |s| parseDecimal(s),
        else => .invalid,
    };
}

/// Parses a decimal operand. The schema promises "a number in decimal", so
/// this validates the spelling first rather than inheriting whatever
/// `parseFloat` happens to accept — it also takes hex, binary, octal, Zig's
/// `_` digit separators, and the words `inf` and `nan`, none of which the
/// schema offers and none of which a JSON number could have carried.
fn parseDecimal(s: []const u8) Operand {
    if (!isDecimal(s)) return .invalid;
    if (std.fmt.parseInt(i64, s, 10)) |i| {
        return .{ .integer = i };
    } else |err| switch (err) {
        // Well-formed digits that do not fit. Reported, never retried as a
        // float: an f64 answer here would be silently wrong.
        error.Overflow => return .out_of_range,
        error.InvalidCharacter => {},
    }
    const f = std.fmt.parseFloat(f128, s) catch return .invalid;
    // `"1e400"` is spelled in decimal but names no value this tool can carry.
    return if (inF64Range(f)) .{ .float = f } else .out_of_range;
}

/// Whether an `f128` names a value the tool's own domain covers.
///
/// f128 is the width the mixed path adds in, not the range it promises: the
/// operands are `number`s, and a JSON number is an f64. Bounding by f64
/// instead of by f128's own limits keeps that promise in both directions —
/// `"1e400"` is rejected rather than answered, and `1e308 + 1e308` is reported
/// as out of range rather than returning a 309-digit value f64 cannot hold.
/// The extra mantissa is still used, so 0.5 + 9007199254740993 stays exact.
fn inF64Range(f: f128) bool {
    return std.math.isFinite(f) and @abs(f) <= std.math.floatMax(f64);
}

/// True for the decimal grammar the schema describes: an optional sign, digits
/// with an optional fractional part (either side may be empty, but not both),
/// and an optional decimal exponent. Deliberately narrower than `parseFloat`.
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

/// The length of the leading run of ASCII digits.
fn digitRun(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and std.ascii.isDigit(s[n])) n += 1;
    return n;
}

pub fn build(environ: *const std.process.Environ.Map) [2]agent.Tool {
    return .{
        .{
            .name = "host_env",
            .description = "Read one of a fixed set of non-secret environment " ++
                "variables from the host process: HOME, LANG, PATH, PWD, SHELL, " ++
                "TERM, USER. Any other name is refused.",
            // `enum` states the same restriction the handler enforces, so the
            // model is told the boundary rather than discovering it by refusal.
            // The handler still checks: a schema is a hint to the model, never
            // a control on what arrives.
            .input_schema =
            \\{"type":"object","properties":{"name":{"type":"string","enum":["HOME","LANG","PATH","PWD","SHELL","TERM","USER"]}},"required":["name"]}
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

test "an integer too large for i64 is reported, not answered as a float" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // i64::MAX + 1. One past the value the test above covers, and the point
    // where treating a failed `parseInt` as "not an integer" would hand the
    // operand to the float path: that answers 9223372036854776000 with
    // is_error false, a wrong number reported as a good one.
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

    // b is exact past 2^53 and a is fractional. Adding in f64 would round the
    // pair to 9007199254740992 — b's exactness discarded because a's was not
    // available. The mixed path adds in f128, which holds both.
    const mixed = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"a\":\"0.5\",\"b\":\"9007199254740993\"}",
        .{},
    );
    const result = try addNumbers(null, a, mixed.value);
    try std.testing.expectEqualStrings("9007199254740993.5", result.text);
    try std.testing.expect(!result.is_error);

    // The same either way round.
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

    // The schema says "a number in decimal". None of these are one, and each
    // would otherwise produce a confident answer: inf, nan, a silent overflow
    // to inf, 32 from hex, and 1000 from Zig's digit separators.
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

    // The spellings the grammar does promise keep working.
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

test "host_env answers only for the allowlisted names" {
    // The regression this pins is a credential disclosure, not a nicety: the
    // demo pre-authorizes `mcp__host__*`, the process inherits its parent's
    // environment, and the tool's argument comes from the model. Drop the
    // allowlist and a turn that asks for AWS_SECRET_ACCESS_KEY gets it.
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

    // Set, secret, and refused — the value must not appear in the reply.
    const secret = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"name\":\"AWS_SECRET_ACCESS_KEY\"}",
        .{},
    );
    const refused = try hostEnv(ctx, a, secret.value);
    try std.testing.expect(refused.is_error);
    try std.testing.expect(std.mem.indexOf(u8, refused.text, "sk-must-not-leak") == null);

    // An allowlisted name that happens to be unset is a different answer from a
    // refusal, and neither reveals whether a non-allowlisted name exists.
    const unset = try std.json.parseFromSlice(std.json.Value, a, "{\"name\":\"TERM\"}", .{});
    try std.testing.expectEqualStrings("not set", (try hostEnv(ctx, a, unset.value)).text);
    const absent = try std.json.parseFromSlice(std.json.Value, a, "{\"name\":\"NOPE\"}", .{});
    try std.testing.expectEqualStrings(
        "not a readable variable",
        (try hostEnv(ctx, a, absent.value)).text,
    );
}
