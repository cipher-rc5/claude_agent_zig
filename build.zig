// build.zig
// Build graph: the `agent` module, the demo executable, and the three test roots.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library, exposed under the name `agent`. Everything outside src/
    // reaches it through this module rather than by a relative path: a file
    // may belong to only one module, and a root under examples/ or tests/
    // cannot import upward out of its own module path.
    const agent_mod = b.addModule("agent", .{
        .root_source_file = b.path("src/agent.zig"),
        .target = target,
        .optimize = optimize,
    });

    const demo_mod = b.createModule(.{
        .root_source_file = b.path("examples/demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_mod.addImport("agent", agent_mod);

    const exe = b.addExecutable(.{
        .name = "claude_agent",
        .root_module = demo_mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the demo client").dependOn(&run.step);

    // Three test roots, because Zig only runs tests reachable from a root's
    // import graph:
    //
    //   src/agent.zig     the library — its test block `_ =`s every module,
    //                     including the ones whose tests cover private decls
    //   tests/all.zig     the black-box suite, which sees only public API
    //   examples/demo.zig the demo, whose test block `_ =`s demo_tools.zig
    //
    // A root reached any other way contributes zero tests silently, so each
    // one is listed here explicitly and each `_ =` above is load-bearing.
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{
        "src/agent.zig",
        "tests/all.zig",
        "examples/demo.zig",
    }) |root| {
        const mod = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        });
        // src/agent.zig is itself the root of `agent` here, so it must not
        // also import it — a file belongs to one module.
        if (!std.mem.eql(u8, root, "src/agent.zig")) mod.addImport("agent", agent_mod);
        const tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
