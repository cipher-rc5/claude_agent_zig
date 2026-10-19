// tests/all.zig
// Test root for the public API suite. Add each test file with `_ =
// @import(...)`; unused imports do not run tests.

test {
    _ = @import("client_test.zig");
    _ = @import("event_test.zig");
    _ = @import("integration_test.zig");
    _ = @import("options_test.zig");
    _ = @import("tool_test.zig");
    _ = @import("transport_contract_test.zig");
}
