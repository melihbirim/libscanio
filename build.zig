const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanio_mod = b.addModule("scanio", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/root.zig"),
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const example = b.addExecutable(.{
        .name = "scan_file",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("examples/scan_file.zig"),
        }),
    });
    example.root_module.addImport("scanio", scanio_mod);
    b.installArtifact(example);
    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_example.addArgs(args);
    const example_step = b.step("scan", "Run the scan_file example");
    example_step.dependOn(&run_example.step);

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("examples/bench.zig"),
        }),
    });
    bench.root_module.addImport("scanio", scanio_mod);
    b.installArtifact(bench);
    const run_bench = b.addRunArtifact(bench);
    run_bench.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the work-not-done benchmark");
    bench_step.dependOn(&run_bench.step);
}
