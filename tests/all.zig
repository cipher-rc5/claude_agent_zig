// tests/all.zig
// Public test root; reference every test module so its tests run.

test {
    _ = @import("client_test.zig");
    _ = @import("event_test.zig");
    _ = @import("integration_test.zig");
    _ = @import("options_test.zig");
    _ = @import("tool_test.zig");
    _ = @import("transport_contract_test.zig");
}
