// tests/event_test.zig
// Black-box tests for `Event`: one protocol line, read through the accessors.

const std = @import("std");
const agent = @import("agent");

test "init event reports loaded skills" {
    const line =
        \\{"type":"system","subtype":"init","session_id":"s1","skills":["code-review","security-check"],"slash_commands":["compact","security-check"]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    var event: agent.Event = .{ .kind = .system, .parsed = parsed };
    defer event.deinit();

    try std.testing.expect(event.arrayContains("skills", "security-check"));
    try std.testing.expect(!event.arrayContains("skills", "deploy"));
    try std.testing.expectEqual(@as(usize, 2), event.getArray("slash_commands").?.len);
}

test "text delta extraction" {
    const line =
        \\{"type":"stream_event","session_id":"abc","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    var event: agent.Event = .{ .kind = .stream_event, .parsed = parsed };
    defer event.deinit();

    try std.testing.expectEqualStrings("hello", event.textDelta().?);
    try std.testing.expectEqualStrings("abc", event.sessionId().?);
}

test "accessors ignore mismatched kinds and shapes" {
    const line =
        \\{"type":"result","session_id":"s1","result":"done","event":{"delta":{"type":"text_delta","text":"x"}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    var event: agent.Event = .{ .kind = .result, .parsed = parsed };
    defer event.deinit();

    try std.testing.expectEqualStrings("done", event.resultText().?);
    // A delta shape on a non-stream_event line is not a token delta.
    try std.testing.expect(event.textDelta() == null);
    try std.testing.expect(event.getArray("result") == null);
    try std.testing.expect(event.getString("missing") == null);
}
