const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. THE LIBRARY MODULE
    const poker_mod = b.addModule("PokerEval", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 2. THE EXECUTABLE (Benchmark)
    // Fix: create the module explicitly since .root_source_file is gone from ExecutableOptions
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = exe_mod,
    });

    // Import the library into the executable
    exe.root_module.addImport("PokerEval", poker_mod);

    // Install the artifact (puts it in zig-out/bin)
    b.installArtifact(exe);

    // Create the 'zig build run' step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the benchmark");
    run_step.dependOn(&run_cmd.step);

    // 3. THE TESTS
    const lib_unit_tests = b.addTest(.{
        .root_module = poker_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
