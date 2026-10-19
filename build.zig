// build.zig
// Builds the library, demo, tests, benchmark, and API docs.

const std = @import("std");
const builtin = @import("builtin");

const manifest = @import("build.zig.zon");

// Require the tested toolchain: the manifest minimum also accepts newer,
// potentially incompatible stdlib APIs.
comptime {
    const required = std.SemanticVersion.parse(manifest.minimum_zig_version) catch unreachable;
    if (builtin.zig_version.order(required) != .eq) {
        @compileError(std.fmt.comptimePrint(
            "claude_agent_zig builds with zig {s} exactly (build.zig.zon .minimum_zig_version); this is zig {s}",
            .{ manifest.minimum_zig_version, builtin.zig_version_string },
        ));
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Run tests whose names contain a filter") orelse &.{};

    // Use a shared module: Zig forbids importing above a module root.
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
    run.addPassthruArgs();
    b.step("run", "Run the demo client").dependOn(&run.step);

    // Each root must reference its test modules; imports alone do not run
    // tests. Cover library internals, public API tests, and demo tools
    // separately.
    const test_step = b.step("test", "Run unit tests");
    const test_compile_step = b.step("test-compile", "Compile all test roots without running them");
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
        // The library root must not import itself as a second module.
        if (!std.mem.eql(u8, root, "src/agent.zig")) mod.addImport("agent", agent_mod);
        const tests = b.addTest(.{ .root_module = mod, .filters = test_filters });
        test_step.dependOn(&b.addRunArtifact(tests).step);
        test_compile_step.dependOn(&tests.step);
    }

    const examples_step = b.step("examples-check", "Compile the complete API examples");
    for ([_][]const u8{ "streaming", "permissions", "initialization", "shutdown" }) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("agent", agent_mod);
        const example = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{name}),
            .root_module = mod,
        });
        examples_step.dependOn(&example.step);
    }

    // Run benchmarks separately in release mode; timing is not a test gate.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/next_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("agent", agent_mod);
    const bench_exe = b.addExecutable(.{
        .name = "next_bench",
        .root_module = bench_mod,
    });
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.addPassthruArgs();
    b.step("bench", "Measure Client.next() over a synthetic stream").dependOn(&bench_run.step);

    // Generate docs from the library object; install only the emitted docs.
    const docs_obj = b.addObject(.{
        .name = "agent",
        .root_module = agent_mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Emit the agent module's autodocs into zig-out/docs").dependOn(&install_docs.step);
}
