const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const xev = b.dependency("libxev", .{ .target = target, .optimize = optimize });
    lib_mod.addImport("xev", xev.module("xev"));

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "dbuz",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("libdbuz", lib_mod);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("libdbuz", lib_mod);
    bench_mod.addImport("xev", xev.module("xev"));

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench);

    const bench_cmd = b.addRunArtifact(bench);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| bench_cmd.addArgs(args);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // much of the test suite relies on a D-Bus session bus being available
    const run_integration_tests = std.process.getEnvVarOwned(
        b.allocator, 
        "DBUS_SESSION_BUS_ADDRESS"
    ) != error.EnvironmentVariableNotFound;
    const options = b.addOptions();
    options.addOption(bool, "run_integration_tests", run_integration_tests);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    lib_unit_tests.root_module.addOptions("build_options", options);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
