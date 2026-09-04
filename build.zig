const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The build script itself always runs on the actual host machine,
    // regardless of what -Dtarget cross-compiles artifacts for — this is
    // real, not cross-compiled: Windows CI runners don't reliably have a
    // "python3" alias (only "python"), found running this on GitHub
    // Actions' windows-latest.
    const python_cmd = if (builtin.os.tag == .windows) "python" else "python3";

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
    const install_c_lib = b.addInstallArtifact(c_lib, .{});
    const c_lib_step = b.step("c-lib", "Build the C ABI shared library (zig-out/lib/libscanio.*)");
    // Scoped to c_lib's own install, not b.getInstallStep() (which pulls
    // in every other example artifact registered anywhere in this file)
    // — that used to break cross-compiling c-lib for Windows, since
    // parser_bench (a POSIX-only diagnostic tool, std.posix.mmap) would
    // get dragged in and fail to compile for a target it was never meant
    // to support. Found by actually trying `-Dtarget=x86_64-windows-gnu`
    // before trusting the release workflow would work, not by assuming.
    c_lib_step.dependOn(&install_c_lib.step);
    // Real gotcha, bitten twice: c_lib and c_api_mod's optimize level comes
    // from whatever -Doptimize this *specific* `zig build` invocation was
    // given (default: Debug). Running `zig build test` or `python-test`
    // WITHOUT -Doptimize=ReleaseFast after building c-lib with it silently
    // rebuilds/overwrites zig-out/lib/libscanio.* at Debug — same binary
    // path, ~10x slower, no error. Always rebuild `c-lib -Doptimize=ReleaseFast`
    // as the LAST command before benchmarking or measuring anything against
    // the .dylib/.so — don't assume a prior ReleaseFast build survived a
    // later `zig build` of anything else.

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
    const install_example = b.addInstallArtifact(example, .{});
    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(&install_example.step);
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
    const install_mem_check = b.addInstallArtifact(mem_check, .{});
    const run_mem_check = b.addRunArtifact(mem_check);
    run_mem_check.step.dependOn(&install_mem_check.step);
    if (b.args) |args| run_mem_check.addArgs(args);
    const mem_check_step = b.step("mem-check", "Run the format-aware Query scan (for memory/throughput comparison)");
    mem_check_step.dependOn(&run_mem_check.step);

    const count_bench = b.addExecutable(.{
        .name = "count_bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("examples/count_bench.zig"),
        }),
    });
    count_bench.root_module.addImport("scanio", scanio_mod);
    count_bench.linkLibC();
    const install_count_bench = b.addInstallArtifact(count_bench, .{});
    const run_count_bench = b.addRunArtifact(count_bench);
    run_count_bench.step.dependOn(&install_count_bench.step);
    if (b.args) |args| run_count_bench.addArgs(args);
    const count_bench_step = b.step("count-bench", "Run Query.count()'s no-WHERE fast path (for xan/duckdb count comparison)");
    count_bench_step.dependOn(&run_count_bench.step);

    const scan_bench = b.addExecutable(.{
        .name = "scan_bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("examples/scan_bench.zig"),
        }),
    });
    scan_bench.root_module.addImport("scanio", scanio_mod);
    scan_bench.linkLibC();
    const install_scan_bench = b.addInstallArtifact(scan_bench, .{});
    const run_scan_bench = b.addRunArtifact(scan_bench);
    run_scan_bench.step.dependOn(&install_scan_bench.step);
    if (b.args) |args| run_scan_bench.addArgs(args);
    const scan_bench_step = b.step("scan-bench", "Run a WHERE-filtered materialized scan (scan_array()-equivalent, for concurrency comparison)");
    scan_bench_step.dependOn(&run_scan_bench.step);

    const parallel_bench = b.addExecutable(.{
        .name = "parallel_bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("examples/parallel_bench.zig"),
        }),
    });
    parallel_bench.root_module.addImport("scanio", scanio_mod);
    parallel_bench.linkLibC();
    const install_parallel_bench = b.addInstallArtifact(parallel_bench, .{});
    const run_parallel_bench = b.addRunArtifact(parallel_bench);
    run_parallel_bench.step.dependOn(&install_parallel_bench.step);
    if (b.args) |args| run_parallel_bench.addArgs(args);
    const parallel_bench_step = b.step("parallel-bench", "Run parallelCountRows(Where) (for multi-threaded comparison)");
    parallel_bench_step.dependOn(&run_parallel_bench.step);

    const filter_bench = b.addExecutable(.{
        .name = "filter_bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("examples/filter_bench.zig"),
        }),
    });
    filter_bench.root_module.addImport("scanio", scanio_mod);
    filter_bench.linkLibC();
    const install_filter_bench = b.addInstallArtifact(filter_bench, .{});
    const run_filter_bench = b.addRunArtifact(filter_bench);
    run_filter_bench.step.dependOn(&install_filter_bench.step);
    if (b.args) |args| run_filter_bench.addArgs(args);
    const filter_bench_step = b.step("filter-bench", "Run a WHERE-filtered scan, counting matches (for grep comparison)");
    filter_bench_step.dependOn(&run_filter_bench.step);

    const collect_bench = b.addExecutable(.{
        .name = "collect_bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("examples/collect_bench.zig"),
        }),
    });
    collect_bench.root_module.addImport("scanio", scanio_mod);
    collect_bench.linkLibC();
    const install_collect_bench = b.addInstallArtifact(collect_bench, .{});
    const run_collect_bench = b.addRunArtifact(collect_bench);
    run_collect_bench.step.dependOn(&install_collect_bench.step);
    if (b.args) |args| run_collect_bench.addArgs(args);
    const collect_bench_step = b.step("collect-bench", "Run a WHERE-filtered, projected scan that collects matches (pure Zig, for a fair xan/qsv comparison with no Python/ctypes layer)");
    collect_bench_step.dependOn(&run_collect_bench.step);

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
    const install_parser_bench = b.addInstallArtifact(parser_bench, .{});
    const run_parser_bench = b.addRunArtifact(parser_bench);
    run_parser_bench.step.dependOn(&install_parser_bench.step);
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
    const install_tok_bench = b.addInstallArtifact(tok_bench, .{});
    const run_tok_bench = b.addRunArtifact(tok_bench);
    run_tok_bench.step.dependOn(&install_tok_bench.step);
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
    const install_bench = b.addInstallArtifact(bench, .{});
    const run_bench = b.addRunArtifact(bench);
    run_bench.step.dependOn(&install_bench.step);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the work-not-done benchmark");
    bench_step.dependOn(&run_bench.step);

    // dlopen() smoke test: Zig's own `test` step runs in-process and never
    // exercises the built shared library the way a real host loads it.
    // This is the equivalent of csvql's #149 regression guard — a
    // real dlopen(), not a compiled-and-trusted assumption.
    const smoke_test = b.addSystemCommand(&.{ python_cmd, "examples/smoke_test.py" });
    smoke_test.step.dependOn(c_lib_step);
    const smoke_test_step = b.step("smoke-test", "dlopen() the built C ABI shared library and exercise it for real (needs python3)");
    smoke_test_step.dependOn(&smoke_test.step);

    const python_test = b.addSystemCommand(&.{ python_cmd, "python/tests/test_scan.py" });
    python_test.step.dependOn(c_lib_step);
    const python_test_step = b.step("python-test", "Run the Python binding test suite (needs python3)");
    python_test_step.dependOn(&python_test.step);

    const node_test = b.addSystemCommand(&.{ "node", "node/test/test.js" });
    node_test.step.dependOn(c_lib_step);
    const node_test_step = b.step("node-test", "Run the Node binding test suite (needs node + `npm install` in node/)");
    node_test_step.dependOn(&node_test.step);
}
