// build.zig
// Build graph: the `agent` module, the demo executable, the three test roots,
// the benchmark, and the autodocs.

const std = @import("std");
const builtin = @import("builtin");

const manifest = @import("build.zig.zon");

// The codebase uses 0.16 APIs (the `Io` interface, `std.json.Stringify`,
// `std.process.spawn`) and is tested on exactly one toolchain. The manifest's
// `minimum_zig_version` is only a floor, so a later zig would be accepted
// there and then fail somewhere inside std instead of here.
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

    // The read-loop benchmark. Its own step rather than part of `test`: it
    // takes seconds, its numbers are only meaningful under a release mode,
    // and a benchmark that "fails" is a regression to read, not a red gate.
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
    if (b.args) |args| bench_run.addArgs(args);
    b.step("bench", "Measure Client.next() over a synthetic stream").dependOn(&bench_run.step);

    // Autodocs for the public surface. An object rather than the executable,
    // so the docs describe the `agent` module and not the demo wrapped around
    // it. The object itself is never installed; only its emitted docs are.
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
