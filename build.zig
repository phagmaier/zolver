const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // We no longer have external dependencies for PokerEval as it's now in src/
    const mod = b.addModule("Poker", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

    const exe = b.addExecutable(.{
        .name = "Poker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Poker", .module = mod },
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const bench_exe = b.addExecutable(.{
        .name = "PokerBench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_bench.addArgs(args);

    const bench_step = b.step("bench", "Run solver benchmark");
    bench_step.dependOn(&run_bench.step);

    const exploit_exe = b.addExecutable(.{
        .name = "PokerExploitCurve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/exploit_curve.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_exploit = b.addRunArtifact(exploit_exe);
    run_exploit.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_exploit.addArgs(args);

    const exploit_step = b.step("exploit", "Run exploitability-vs-iters harness");
    exploit_step.dependOn(&run_exploit.step);

    const exploit_tests = b.addTest(.{
        .root_module = exploit_exe.root_module,
    });
    const run_exploit_tests = b.addRunArtifact(exploit_tests);
    test_step.dependOn(&run_exploit_tests.step);
}
