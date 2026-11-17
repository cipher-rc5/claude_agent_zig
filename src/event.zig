// src/event.zig
// Owned protocol events and field accessors.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Unknown wire types map to `unknown`; use `else` in switches for future variants.
pub const Kind = enum {
    /// Session lifecycle: `init`, `api_retry`, `plugin_install`.
    system,
    assistant,
    user,
    /// Terminal turn message with cost and session metadata.
    result,
    /// Token-level delta, present only with `include_partial_messages`.
    stream_event,
    control_request,
    sdk_control_request,
    control_response,
    unknown,
};

/// One protocol line; owns its parsed tree.
pub const Event = struct {
    kind: Kind,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(event: *Event) void {
        event.parsed.deinit();
        event.* = undefined;
    }

    /// Full parsed line; inspect nested values with `objectField` and `stringField`.
    pub fn root(event: Event) std.json.Value {
        return event.parsed.value;
    }

    pub fn getString(event: Event, key: []const u8) ?[]const u8 {
        return stringField(event.parsed.value, key);
    }

    /// Array field, such as `skills` or `tools` on `system/init`.
    pub fn getArray(event: Event, key: []const u8) ?[]const std.json.Value {
        return switch (objectField(event.parsed.value, key) orelse return null) {
            .array => |a| a.items,
            else => null,
        };
    }

    /// Tests membership in a string-array field, such as loaded skills or tools.
    pub fn arrayContains(event: Event, key: []const u8, needle: []const u8) bool {
        const items = event.getArray(key) orelse return false;
        for (items) |item| {
            switch (item) {
                .string => |s| if (std.mem.eql(u8, s, needle)) return true,
                else => {},
            }
        }
        return false;
    }

    pub fn subtype(event: Event) ?[]const u8 {
        return event.getString("subtype");
    }

    pub fn sessionId(event: Event) ?[]const u8 {
        return event.getString("session_id");
    }

    /// Text of a `stream_event` `text_delta`, if this event is one.
    pub fn textDelta(event: Event) ?[]const u8 {
        if (event.kind != .stream_event) return null;
        const inner = objectField(event.parsed.value, "event") orelse return null;
        const delta = objectField(inner, "delta") orelse return null;
        const delta_type = stringField(delta, "type") orelse return null;
        if (!std.mem.eql(u8, delta_type, "text_delta")) return null;
        return stringField(delta, "text");
    }

    /// Final text of a `result` event.
    pub fn resultText(event: Event) ?[]const u8 {
        if (event.kind != .result) return null;
        return event.getString("result");
    }
};

/// Streaming projection. Strings and raw JSON are borrowed until the client's
/// next read (either API), or close. Use `toOwned` to retain an event or inspect
/// arbitrary fields. Unknown fields are validated without building their trees.
pub const EventView = struct {
    kind: Kind = .unknown,
    raw: []const u8,
    subtype_value: ?[]const u8 = null,
    session_id_value: ?[]const u8 = null,
    delta_type: ?[]const u8 = null,
    delta_text: ?[]const u8 = null,
    result_text: ?[]const u8 = null,

    pub fn subtype(event: EventView) ?[]const u8 {
        return event.subtype_value;
    }

    pub fn sessionId(event: EventView) ?[]const u8 {
        return event.session_id_value;
    }

    pub fn textDelta(event: EventView) ?[]const u8 {
        if (event.kind != .stream_event) return null;
        if (!std.mem.eql(u8, event.delta_type orelse return null, "text_delta")) return null;
        return event.delta_text;
    }

    pub fn resultText(event: EventView) ?[]const u8 {
        return if (event.kind == .result) event.result_text else null;
    }

    pub fn toOwned(event: EventView, allocator: Allocator) std.json.ParseError(std.json.Scanner)!Event {
        return .{ .kind = event.kind, .parsed = try parseOwned(allocator, event.raw) };
    }
};

const ViewParseError = std.json.ParseError(std.json.Scanner);

// Avoid projecting canonical control frames only to build their full trees for
// handlers. This is a routing hint, never validation: the caller must parse the
// complete frame before dispatch. Other field orders use the normal projection.
pub fn controlPrefix(line: []const u8) ?Kind {
    const text = std.mem.trimStart(u8, line, " \t\r\n");
    inline for (.{ Kind.control_request, Kind.sdk_control_request, Kind.control_response }) |kind| {
        if (std.mem.startsWith(u8, text, "{\"type\":\"" ++ @tagName(kind) ++ "\"")) return kind;
    }
    return null;
}

// Small objects use stack storage. Wide objects switch to hashing so unknown
// fields do not create quadratic work. Keys borrow the line or decoding arena.
const ObjectKeys = struct {
    small: [8][]const u8 = undefined,
    len: usize = 0,
    wide: std.StringHashMapUnmanaged(void) = .empty,

    fn add(keys: *ObjectKeys, allocator: Allocator, key: []const u8) ViewParseError!void {
        if (keys.len < keys.small.len) {
            for (keys.small[0..keys.len]) |prior| {
                if (std.mem.eql(u8, prior, key)) return error.DuplicateField;
            }
            keys.small[keys.len] = key;
        } else {
            if (keys.len == keys.small.len) {
                for (keys.small) |prior| try keys.wide.put(allocator, prior, {});
            }
            const entry = try keys.wide.getOrPut(allocator, key);
            if (entry.found_existing) return error.DuplicateField;
        }
        keys.len += 1;
    }
};

const ViewParser = struct {
    scanner: std.json.Scanner,
    allocator: Allocator,
    view: EventView,

    const Scope = enum { root, event, delta, skip };

    fn string(parser: *ViewParser) ViewParseError!?[]const u8 {
        if (try parser.scanner.peekNextTokenType() != .string) {
            try parser.value(.skip);
            return null;
        }
        return switch (try parser.scanner.nextAlloc(parser.allocator, .alloc_if_needed)) {
            .string, .allocated_string => |text| text,
            else => unreachable,
        };
    }

    fn value(parser: *ViewParser, scope: Scope) ViewParseError!void {
        switch (try parser.scanner.peekNextTokenType()) {
            .object_begin => try parser.object(scope),
            .array_begin => {
                _ = try parser.scanner.next();
                while (try parser.scanner.peekNextTokenType() != .array_end) try parser.value(.skip);
                _ = try parser.scanner.next();
            },
            .string, .number, .true, .false, .null => try parser.scanner.skipValue(),
            else => return error.UnexpectedToken,
        }
    }

    fn object(parser: *ViewParser, scope: Scope) ViewParseError!void {
        _ = try parser.scanner.next();
        var keys: ObjectKeys = .{};
        while (try parser.scanner.peekNextTokenType() != .object_end) {
            if (try parser.scanner.peekNextTokenType() != .string) return error.UnexpectedToken;
            const key = (try parser.string()).?;
            try keys.add(parser.allocator, key);
            switch (scope) {
                .root => {
                    if (std.mem.eql(u8, key, "type")) {
                        const name = try parser.string();
                        parser.view.kind = if (name) |n| std.meta.stringToEnum(Kind, n) orelse .unknown else .unknown;
                    } else if (std.mem.eql(u8, key, "subtype")) {
                        parser.view.subtype_value = try parser.string();
                    } else if (std.mem.eql(u8, key, "session_id")) {
                        parser.view.session_id_value = try parser.string();
                    } else if (std.mem.eql(u8, key, "result")) {
                        parser.view.result_text = try parser.string();
                    } else if (std.mem.eql(u8, key, "event")) {
                        try parser.value(.event);
                    } else try parser.value(.skip);
                },
                .event => {
                    try parser.value(if (std.mem.eql(u8, key, "delta")) .delta else .skip);
                },
                .delta => {
                    if (std.mem.eql(u8, key, "type")) {
                        parser.view.delta_type = try parser.string();
                    } else if (std.mem.eql(u8, key, "text")) {
                        parser.view.delta_text = try parser.string();
                    } else try parser.value(.skip);
                },
                .skip => try parser.value(.skip),
            }
        }
        _ = try parser.scanner.next();
    }
};

// The client checks the nesting bound before entering this recursive scanner.
// The allocator is a resettable client arena, including for escaped strings.
pub fn parseView(allocator: Allocator, line: []const u8) ViewParseError!EventView {
    var parser: ViewParser = .{
        .scanner = .initCompleteInput(allocator, line),
        .allocator = allocator,
        .view = .{ .raw = line },
    };
    defer parser.scanner.deinit();
    try parser.value(.root);
    if (try parser.scanner.next() != .end_of_document) return error.UnexpectedToken;
    return parser.view;
}

/// Object field, or null if absent or `value` is not an object.
pub fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    return obj.get(key);
}

pub fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (objectField(value, key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub const LineShape = struct { depth_ok: bool = true, objects: u8 = 0, arrays: u8 = 0 };

// Reuse the nesting pass to size small owned-event arenas. Saturating the
// counter keeps large flat documents cheap; they use the standard parser.
pub fn inspectLine(text: []const u8) LineShape {
    var shape: LineShape = .{};
    var depth: usize = 0;
    var cursor: usize = 0;
    while (cursor < text.len) : (cursor += 1) {
        switch (text[cursor]) {
            '"' => {
                var search = cursor + 1;
                while (std.mem.indexOfScalarPos(u8, text, search, '"')) |quote| {
                    var escape_start = quote;
                    while (escape_start > cursor and text[escape_start - 1] == '\\') escape_start -= 1;
                    if ((quote - escape_start) % 2 == 0) {
                        cursor = quote;
                        break;
                    }
                    search = quote + 1;
                } else return shape; // The JSON parser reports unterminated strings.
            },
            '{', '[' => {
                if (text[cursor] == '{') shape.objects +|= 1 else shape.arrays +|= 1;
                depth += 1;
                if (depth > 128) {
                    shape.depth_ok = false;
                    return shape;
                }
            },
            '}', ']' => depth -|= 1,
            else => {},
        }
    }
    return shape;
}

// Reserve sizes were checked against deltas, controls, result text, tool
// arrays and wide objects. The depth pass supplies this count without another
// scan on the client's hot path; arbitrary conversions inspect small lines.
// Arrays retain the standard path: growing array storage makes a fixed reserve
// unpredictable. Flat objects use a smaller reserve than nested envelopes.
pub fn parseOwned(gpa: Allocator, line: []const u8) std.json.ParseError(std.json.Scanner)!std.json.Parsed(std.json.Value) {
    const shape: LineShape = if (line.len >= 128 and line.len <= 2048) inspectLine(line) else .{};
    return parseOwnedWithShape(gpa, line, shape);
}

pub fn parseOwnedWithShape(gpa: Allocator, line: []const u8, shape: LineShape) std.json.ParseError(std.json.Scanner)!std.json.Parsed(std.json.Value) {
    const reserve: usize = if (line.len < 128 or line.len > 2048 or shape.objects == 0 or shape.objects > 8 or shape.arrays != 0)
        0
    else if (shape.objects < 3)
        512
    else
        1792;
    if (reserve == 0) return std.json.parseFromSlice(std.json.Value, gpa, line, .{ .allocate = .alloc_always });
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const seed = try a.alloc(u8, reserve);
    a.free(seed);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{ .allocate = .alloc_always });
    return .{ .arena = arena, .value = value };
}

test "streaming view preserves projections and validates skipped data" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        \\{"type":"stream_event","session_id":"s","event":{"delta":{"type":"text_delta","text":"hi\n\uD83D\uDE03"}},"future":{"deep":[true,1,null,{"x":"ok"}]}}
        ,
        \\{"event":{"delta":{"text":"reordered","type":"text_delta"}},"type":"stream_event"}
        ,
        \\{"type":"result","result":"done","subtype":"success"}
        ,
        \\{"type":null,"event":[{"delta":{"type":"text_delta","text":"ignored"}}]}
        ,
        \\{"type":"stream_event","event":{"delta":{"type":false,"text":"ignored"}}}
        ,
        \\{"type":"future_kind","session_id":"s"}
        ,
        "[1, true, null, {\"type\":\"result\"}]",
    };
    for (cases) |line| {
        _ = arena.reset(.retain_capacity);
        const view = try parseView(arena.allocator(), line);
        var owned = try view.toOwned(std.testing.allocator);
        defer owned.deinit();
        try expectOptionalString(owned.subtype(), view.subtype());
        try expectOptionalString(owned.sessionId(), view.sessionId());
        try expectOptionalString(owned.textDelta(), view.textDelta());
        try expectOptionalString(owned.resultText(), view.resultText());
    }
    for ([_][]const u8{
        \\{"type":"result","type":"system"}
        ,
        \\{"future":{"x":1,"\u0078":2}}
        ,
        \\{"future":[{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6,"g":7,"h":8,"i":9,"a":10}]}
        ,
        \\{"future":[1,]}
        ,
        \\{"future":"\uD800"}
        ,
        "{} {}",
    }) |line| {
        _ = arena.reset(.retain_capacity);
        if (parseView(arena.allocator(), line)) |_| return error.ExpectedInvalidJson else |_| {}
    }
}

fn expectOptionalString(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |text| {
        try std.testing.expectEqualStrings(text, actual orelse return error.MissingString);
    } else try std.testing.expect(actual == null);
}

fn allocationFailureParse(allocator: Allocator, borrowed: bool, line: []const u8) !void {
    if (borrowed) {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const view = try parseView(arena.allocator(), line);
        var owned = try view.toOwned(allocator);
        defer owned.deinit();
        try std.testing.expect(owned.root() == .object);
    } else {
        const parsed = try parseOwned(allocator, line);
        defer parsed.deinit();
    }
}

test "owned and streaming parsers release every allocation failure" {
    const cases = [_][]const u8{
        \\{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"escaped\n\u1234"}},"future":{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6,"g":7,"h":8,"i":9}}
        ,
        "{\"type\":\"result\",\"result\":\"" ++ @as([128]u8, @splat('x')) ++ "\"}",
        \\{"type":"system","tools":["one","two","three","four","five","six","seven","eight","nine","ten"],"session_id":"array-path"}
        ,
    };
    for (cases) |line| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureParse, .{ false, line });
        try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureParse, .{ true, line });
    }
}
