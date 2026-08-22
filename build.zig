// build.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "claude_agent",
        .root_module = module,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the demo client").dependOn(&run.step);

    // src/agent.zig pulls in every library module, and src/main.zig references
    // the demo tools from a test block so the test runner reaches them, so
    // between them the two roots cover the whole tree.
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/agent.zig", "src/main.zig" }) |root| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
