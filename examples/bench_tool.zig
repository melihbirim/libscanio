//! One binary, four modes — replaces what used to be four separate
//! ~25-30 line files (scan_file.zig, mem_check.zig, count_bench.zig,
//! filter_bench.zig) that were each just argv-parse + open + loop +
//! timer + print, differing only in which single scanio call got timed.
//! Consolidated after a repo-wide audit flagged the duplication — see
//! ROADMAP.md for why these four specifically (not scan_bench.zig,
//! parallel_bench.zig, collect_bench.zig, tokenizer_bench.zig, or
//! parser_bench.zig, which stayed separate) and why this wasn't done
//! blind.
//!
//! The mode is baked into each `zig build <step>` invocation by
//! build.zig itself (see its own comment there) — a caller typing
//! `zig build mem-check -- <file>` never sees or types "mem-check"
//! twice; the documented CLI surface in docs/BENCHMARKS.md is
//! byte-for-byte unchanged.
const std = @import("std");
const scanio = @import("scanio");

pub fn main() !void {
    // c_allocator, not GeneralPurposeAllocator — see ndjson.zig's doc
    // comment for why that choice alone was a real, measured 66x
    // difference for NDJSON. Benchmark with the allocator a real caller
    // ships, or the number isn't the number a real caller sees.
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("usage: bench_tool <mode> <path> [args...]\n", .{});
        return;
    }
    const mode = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, mode, "scan-file")) return scanFile(allocator, rest);
    if (std.mem.eql(u8, mode, "mem-check")) return memCheck(allocator, rest);
    if (std.mem.eql(u8, mode, "count-bench")) return countBench(allocator, rest);
    if (std.mem.eql(u8, mode, "filter-bench")) return filterBench(allocator, rest);
    std.debug.print("unknown mode: {s}\n", .{mode});
}

fn printRate(label: []const u8, count: usize, secs: f64) void {
    std.debug.print("{s}: {d} rows in {d:.3}s ({d:.1} rows/sec)\n", .{ label, count, secs, @as(f64, @floatFromInt(count)) / secs });
}

/// Raw Scanner.next() loop, CSV-only — the lowest layer, no format
/// dispatch, no WHERE.
fn scanFile(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 1) return std.debug.print("usage: bench_tool scan-file <path>\n", .{});
    var scanner = try scanio.Scanner.open(allocator, args[0]);
    defer scanner.deinit();

    var count: usize = 0;
    const t0 = std.time.nanoTimestamp();
    while (try scanner.next()) |_| count += 1;
    const t1 = std.time.nanoTimestamp();
    printRate("scan-file", count, @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0);
}

/// Format-aware Query.next() loop, no WHERE — splits every field of
/// every row. NOT the same thing count-bench measures (that one never
/// splits a field at all).
fn memCheck(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 1) return std.debug.print("usage: bench_tool mem-check <path>\n", .{});
    var q = try scanio.Query.open(allocator, args[0], .{});
    defer q.deinit();

    var count: usize = 0;
    const t0 = std.time.nanoTimestamp();
    while (try q.next()) |_| count += 1;
    const t1 = std.time.nanoTimestamp();
    printRate("mem-check", count, @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0);
}

/// Query.count()'s no-WHERE fast path specifically (newline/object
/// counting, never splits a field) — the fair comparison to a tool
/// like `xan count`, which also doesn't parse fields for a bare count.
fn countBench(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 1) return std.debug.print("usage: bench_tool count-bench <path>\n", .{});
    var q = try scanio.Query.open(allocator, args[0], .{});
    defer q.deinit();

    const t0 = std.time.nanoTimestamp();
    const count = try q.count();
    const t1 = std.time.nanoTimestamp();
    const secs = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
    std.debug.print("count={d} time={d:.3}s ({d:.1} rows/sec)\n", .{ count, secs, @as(f64, @floatFromInt(count)) / secs });
}

/// WHERE-eq scan, counting matches — the fair comparison to `grep`.
fn filterBench(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3) return std.debug.print("usage: bench_tool filter-bench <path> <column> <value>\n", .{});
    const path = args[0];
    const column = args[1];
    const value = args[2];

    var probe = try scanio.Query.open(allocator, path, .{});
    const col_idx = probe.columnIndex(column) orelse return error.UnknownColumn;
    probe.deinit();

    var q = try scanio.Query.open(allocator, path, .{
        .where = &.{scanio.Predicate.init(col_idx, .eq, value)},
    });
    defer q.deinit();

    var count: usize = 0;
    const t0 = std.time.nanoTimestamp();
    while (try q.next()) |_| count += 1;
    const t1 = std.time.nanoTimestamp();
    const secs = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
    std.debug.print("matches={d} time={d:.3}s\n", .{ count, secs });
}
