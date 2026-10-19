// src/event.zig
// Owned protocol events and field accessors.

const std = @import("std");

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
