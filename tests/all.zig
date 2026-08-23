// tests/all.zig
// Test root for the black-box suite: every file under tests/ is listed here.
//
// The `_ =` form is load-bearing. Zig only runs tests it can reach from a test
// root's import graph, and a plain `const x = @import("foo.zig")` does not
// pull in foo.zig's test blocks. Adding a test file means adding a line here;
// without one the file compiles, passes, and runs nothing.

test {
    _ = @import("client_test.zig");
    _ = @import("event_test.zig");
    _ = @import("integration_test.zig");
    _ = @import("options_test.zig");
    _ = @import("tool_test.zig");
}
