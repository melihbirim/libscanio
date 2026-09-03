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

    // C ABI: its own module (not folded into scanio's own test tree, to
    // avoid a root.zig <-> c_api.zig import cycle) and its own test run.
    const c_api_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/c_api.zig"),
    });
    c_api_mod.addImport("scanio", scanio_mod);
    const c_api_tests = b.addTest(.{ .root_module = c_api_mod });
    const run_c_api_tests = b.addRunArtifact(c_api_tests);
    test_step.dependOn(&run_c_api_tests.step);

    const c_lib = b.addLibrary(.{
        .name = "scanio",
        .linkage = .dynamic,
        .root_module = c_api_mod,
    });
    c_lib.linkLibC();
    c_lib.installHeader(b.path("include/libscanio.h"), "libscanio.h");
    b.installArtifact(c_lib);
    const c_lib_step = b.step("c-lib", "Build the C ABI shared library (zig-out/lib/libscanio.*)");
    c_lib_step.dependOn(b.getInstallStep());

    const example = b.addExecutable(.{
        .name = "scan_file",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("examples/scan_file.zig"),
        }),
    });
    example.root_module.addImport("scanio", scanio_mod);
    example.linkLibC();
    b.installArtifact(example);
    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_example.addArgs(args);
    const example_step = b.step("scan", "Run the scan_file example");
    example_step.dependOn(&run_example.step);

    const mem_check = b.addExecutable(.{
        .name = "mem_check",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("examples/mem_check.zig"),
        }),
    });
    mem_check.root_module.addImport("scanio", scanio_mod);
    mem_check.linkLibC();
    b.installArtifact(mem_check);
    const run_mem_check = b.addRunArtifact(mem_check);
    run_mem_check.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_mem_check.addArgs(args);
    const mem_check_step = b.step("mem-check", "Run the format-aware Query scan (for memory/throughput comparison)");
    mem_check_step.dependOn(&run_mem_check.step);

    const json_parser_mod = b.addModule("json_parser", .{
        .root_source_file = b.path("src/json_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parser_bench = b.addExecutable(.{
        .name = "parser_bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("examples/parser_bench.zig"),
        }),
    });
    parser_bench.root_module.addImport("json_parser", json_parser_mod);
    parser_bench.linkLibC();
    b.installArtifact(parser_bench);
    const run_parser_bench = b.addRunArtifact(parser_bench);
    run_parser_bench.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_parser_bench.addArgs(args);
    const parser_bench_step = b.step("parser-bench", "Isolated json_parser.zig throughput (no Query/NdjsonScanner layer)");
    parser_bench_step.dependOn(&run_parser_bench.step);

    const json_simd_mod = b.addModule("json_simd", .{
        .root_source_file = b.path("src/json_simd.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tok_bench = b.addExecutable(.{
        .name = "tokenizer_bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("examples/tokenizer_bench.zig"),
        }),
    });
    tok_bench.root_module.addImport("json_simd", json_simd_mod);
    b.installArtifact(tok_bench);
    const run_tok_bench = b.addRunArtifact(tok_bench);
    run_tok_bench.step.dependOn(b.getInstallStep());
    const tok_bench_step = b.step("tok-bench", "Isolated SIMD tokenizer throughput (no allocation, no field parsing)");
    tok_bench_step.dependOn(&run_tok_bench.step);

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("examples/bench.zig"),
        }),
    });
    bench.root_module.addImport("scanio", scanio_mod);
    bench.linkLibC();
    b.installArtifact(bench);
    const run_bench = b.addRunArtifact(bench);
    run_bench.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the work-not-done benchmark");
    bench_step.dependOn(&run_bench.step);

    // dlopen() smoke test: Zig's own `test` step runs in-process and never
    // exercises the built shared library the way a real host loads it.
    // This is the equivalent of csvql's #149 regression guard — a
    // real dlopen(), not a compiled-and-trusted assumption.
    const smoke_test = b.addSystemCommand(&.{ "python3", "examples/smoke_test.py" });
    smoke_test.step.dependOn(c_lib_step);
    const smoke_test_step = b.step("smoke-test", "dlopen() the built C ABI shared library and exercise it for real (needs python3)");
    smoke_test_step.dependOn(&smoke_test.step);

    const python_test = b.addSystemCommand(&.{ "python3", "python/tests/test_scan.py" });
    python_test.step.dependOn(c_lib_step);
    const python_test_step = b.step("python-test", "Run the Python binding test suite (needs python3)");
    python_test_step.dependOn(&python_test.step);
}
