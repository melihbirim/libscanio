const std = @import("std");
const builtin = @import("builtin");

/// Auto-detect the Node.js include directory by running `node` at build
/// time — same approach as csvql's own build.zig (this project's
/// sibling), the source of this N-API pattern.
fn detectNodeInclude(allocator: std.mem.Allocator) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "node", "-e",
            "const p=require('path');process.stdout.write(p.join(process.execPath,'../../include/node'))",
        },
    }) catch return null;
    allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) {
        allocator.free(result.stdout);
        return null;
    }
    return result.stdout;
}

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

    // WHERE-string parsing for the N-API Node binding — its own module
    // (not node_binding.zig itself, which needs node_api.h available to
    // even compile) so `zig build test` covers it without needing Node
    // headers at all.
    const where_parser_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/where_parser.zig"),
    });
    where_parser_mod.addImport("scanio", scanio_mod);
    const where_parser_tests = b.addTest(.{ .root_module = where_parser_mod });
    const run_where_parser_tests = b.addRunArtifact(where_parser_tests);
    test_step.dependOn(&run_where_parser_tests.step);

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

    // Node.js N-API addon — zig build node -Doptimize=ReleaseFast
    // SAME GOTCHA AS c-lib ABOVE, bitten a third time: benchmarked this
    // addon once with a plain `zig build node` (Debug, no flag) and got
    // a real, false "7x slower than expected" result — it was purely a
    // Debug-vs-ReleaseFast difference, not a real regression (see
    // ROADMAP.md's M5b follow-up for the full story). Always pass
    // -Doptimize=ReleaseFast when building this for anything other than
    // a quick compile-check.
    // Output: zig-out/lib/scanio.node, see src/node_binding.zig's doc
    // comment for the design.
    const node_include = b.option(
        []const u8,
        "node-include",
        "Path to Node.js include dir containing node_api.h (auto-detected if omitted)",
    ) orelse detectNodeInclude(b.allocator);

    // Windows-only: node.lib, the import library that resolves napi_*
    // symbols at link time — a Windows DLL must resolve every symbol at
    // link time, unlike a POSIX .so/.dylib which may leave them for the
    // dynamic loader. Without it the addon links with an "undefined
    // symbol: napi_..." WARNING (not an error) and crashes on first call.
    // See ci.yml's Windows job for where this actually gets fetched.
    const node_lib = b.option(
        []const u8,
        "node-lib",
        "Path to node.lib (Windows only — resolves napi_* at link time)",
    );

    var node_install_step: ?*std.Build.Step = null;
    if (node_include) |inc| {
        const node_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/node_binding.zig"),
        });
        node_mod.addImport("scanio", scanio_mod);
        const node_addon = b.addLibrary(.{
            .name = "scanio_node",
            .linkage = .dynamic,
            .root_module = node_mod,
        });
        node_addon.linkLibC();
        node_addon.addIncludePath(.{ .cwd_relative = inc });
        // On POSIX, N-API symbols resolve at dlopen() time from the host
        // process rather than at link time — Windows cannot do that, see
        // the node_lib comment above.
        node_addon.linker_allow_shlib_undefined = true;
        // Force the LLVM backend for this addon, at every optimize level.
        // Zig 0.15.2's self-hosted x86_64 backend (the DEFAULT for Debug
        // builds) miscompiles this file: `zig build node-test` — which
        // rebuilds the addon at Debug, per the -Doptimize gotcha
        // documented above — segfaults on the FIRST openScan() call that
        // passes a `columns` projection. Reduced all the way down: the
        // caller passes a garbage value in a callee-saved register, so
        // the callee faults dereferencing it (address 0x20) in its own
        // prologue — it reproduces in any std container call
        // (ArrayList.append, HashMap.put) reached at that point, and
        // `std.debug.print` is broken on those worker threads for the
        // same reason. Not a bug in this file: the identical source at
        // -Doptimize=ReleaseFast (LLVM) and at Debug with use_llvm
        // passes all 31 addon + 53 wrapper tests. CI never hit it
        // because it builds ReleaseFast and runs the test scripts
        // directly, never through `zig build node-test`. Revisit when
        // this project moves off 0.15.2 — check whether the self-hosted
        // backend has been fixed before dropping this line.
        node_addon.use_llvm = true;
        if (node_lib) |nlib| {
            node_addon.addObjectFile(.{ .cwd_relative = nlib });
        }

        const install_node = b.addInstallFileWithDir(
            node_addon.getEmittedBin(),
            .lib,
            "scanio.node",
        );

        const node_step = b.step("node", "Build Node.js N-API addon (zig-out/lib/scanio.node)");
        node_step.dependOn(&install_node.step);
        node_install_step = &install_node.step;
    } else {
        const node_step = b.step("node", "Build Node.js N-API addon (requires node in PATH)");
        _ = node_step;
    }

    // scan-file/mem-check/count-bench/filter-bench share ONE compiled
    // binary (examples/bench_tool.zig) with a mode dispatch — these four
    // used to be four separate files, each just argv-parse + open + loop
    // + timer + print with no meaningfully different scaffolding. Each
    // step below bakes its own mode in as the first real arg, so the
    // documented CLI (`zig build mem-check -- <file>`, cited verbatim in
    // docs/BENCHMARKS.md) is unchanged — callers never type the mode.
    const bench_tool = b.addExecutable(.{
        .name = "bench_tool",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("examples/bench_tool.zig"),
        }),
    });
    bench_tool.root_module.addImport("scanio", scanio_mod);
    bench_tool.linkLibC();
    const install_bench_tool = b.addInstallArtifact(bench_tool, .{});

    const bench_tool_modes = [_]struct { mode: []const u8, step: []const u8, desc: []const u8 }{
        .{ .mode = "scan-file", .step = "scan", .desc = "Run the raw Scanner.next() loop example" },
        .{ .mode = "mem-check", .step = "mem-check", .desc = "Run the format-aware Query scan (for memory/throughput comparison)" },
        .{ .mode = "count-bench", .step = "count-bench", .desc = "Run Query.count()'s no-WHERE fast path (for xan count comparison)" },
        .{ .mode = "filter-bench", .step = "filter-bench", .desc = "Run a WHERE-filtered scan, counting matches (for grep comparison)" },
    };
    for (bench_tool_modes) |m| {
        const run = b.addRunArtifact(bench_tool);
        run.step.dependOn(&install_bench_tool.step);
        run.addArg(m.mode);
        if (b.args) |args| run.addArgs(args);
        const step = b.step(m.step, m.desc);
        step.dependOn(&run.step);
    }

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

    // Node binding — N-API addon. `zig build node` must have already
    // produced zig-out/lib/scanio.node; these tests load it directly,
    // no `npm install` needed at all (zero runtime dependencies).
    const node_addon_test = b.addSystemCommand(&.{ "node", "node/test/addon_test.js" });
    if (node_install_step) |s| node_addon_test.step.dependOn(s);
    const node_wrapper_test = b.addSystemCommand(&.{ "node", "node/test/test.js" });
    node_wrapper_test.step.dependOn(&node_addon_test.step);
    const node_test_step = b.step("node-test", "Run the Node binding test suite (builds the N-API addon first)");
    node_test_step.dependOn(&node_wrapper_test.step);
}
