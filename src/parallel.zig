//! M9: parallel scan — bounded memory by construction, same discipline as
//! Scanner/NdjsonScanner (see root.zig, ndjson.zig): no mmap of the whole
//! file. Each worker thread does its own CHUNK_SIZE-bounded pread() loop
//! over a disjoint byte range of the SAME shared file handle — pread()
//! doesn't touch a shared file-position cursor the way read() does, so
//! concurrent pread() calls on one std.fs.File are safe (POSIX: pread(2)
//! syscall; Windows: ReadFile with an explicit OVERLAPPED offset) without
//! needing a separate file handle per thread. Peak RSS across all workers
//! combined is bounded by (WORKER_CHUNK_SIZE * num_threads), not file
//! size — a 10GB file with 8 threads costs the same working set as a
//! 1.25GB/thread file would, not 10GB.
//!
//! Deliberately a separate, standalone entry point — NOT a change to
//! Query.next()'s streaming, single-threaded contract. See ROADMAP.md's
//! M9 entry for why: threading a per-row generator API means either
//! buffering full results before the first next() call (defeats the
//! point of streaming) or maintaining an ordered cross-thread merge queue
//! (thread pool lifecycle now has to survive across next() calls, and
//! every consumer — C ABI, Python, Node, MCP — would need re-verifying
//! for dlopen()-safety under threads). A caller who wants parallel speed
//! opts in explicitly by calling a different function; next()'s existing
//! callers are untouched.
//!
//! First cut: parallelCountRows() — the no-WHERE-clause row-count case.
//! Chosen first because it needs no field splitting at all (pure newline
//! counting, embarrassingly parallel, no cross-thread state beyond a
//! per-worker integer) — it proves the range-splitting and line-boundary
//! alignment logic is correct (checked against Scanner.countRemaining(),
//! the known-correct single-thread path) before anything harder (WHERE
//! filtering, field projection across threads) gets built on top of it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const query_mod = @import("query.zig");

pub const ParallelError = error{EmptyFile};

const Range = struct { start: u64, end: u64 };

/// Read-ahead window used only while aligning a range boundary to the
/// next newline — separate from WORKER_CHUNK_SIZE (the steady-state read
/// size once a worker is inside its own range). 64KB comfortably covers
/// any real CSV/NDJSON row; doubles on the rare pathological line longer
/// than that rather than failing outright.
const ALIGN_LOOKAHEAD_INITIAL: usize = 64 * 1024;

/// Finds the first newline at or after `approx`, returns the offset just
/// past it (the start of the next full line) — never splits a row across
/// two workers' ranges. Reads via pread() at a growing window size
/// instead of loading the whole remaining file, so a pathologically long
/// single line costs at most a few doublings, not a full-file read.
fn alignForwardToNewline(file: std.fs.File, allocator: Allocator, approx: u64, file_size: u64) !u64 {
    if (approx >= file_size) return file_size;
    var window_size: usize = ALIGN_LOOKAHEAD_INITIAL;
    while (true) {
        const remaining: u64 = file_size - approx;
        const to_read: usize = @intCast(@min(@as(u64, window_size), remaining));
        const buf = try allocator.alloc(u8, to_read);
        defer allocator.free(buf);
        const n = try file.pread(buf, approx);
        if (std.mem.indexOfScalar(u8, buf[0..n], '\n')) |idx| {
            return approx + idx + 1;
        }
        if (approx + n >= file_size) return file_size; // no newline before EOF
        if (@as(u64, window_size) >= remaining) return file_size; // whole rest of file is one line
        window_size *= 2;
    }
}

/// Splits [0, file_size) into `num_threads` disjoint, line-boundary-
/// aligned ranges. Only the num_threads-1 INTERNAL boundaries need
/// aligning — the first range always starts at 0, the last always ends
/// at file_size, both already valid row boundaries by construction.
fn splitRanges(allocator: Allocator, file: std.fs.File, file_size: u64, num_threads: usize) ![]Range {
    const ranges = try allocator.alloc(Range, num_threads);
    errdefer allocator.free(ranges);
    const approx_chunk = file_size / num_threads;
    var start: u64 = 0;
    for (0..num_threads) |i| {
        const is_last = i == num_threads - 1;
        const end = if (is_last) file_size else try alignForwardToNewline(file, allocator, start + approx_chunk, file_size);
        ranges[i] = .{ .start = start, .end = end };
        start = end;
    }
    return ranges;
}

const WORKER_CHUNK_SIZE = 256 * 1024; // matches root.zig's CHUNK_SIZE default

const CountWorker = struct {
    file: std.fs.File,
    range: Range,
    result: usize = 0,
    err: ?anyerror = null,
};

fn countWorkerRun(w: *CountWorker) void {
    w.result = countRange(w.file, w.range) catch |e| {
        w.err = e;
        return;
    };
}

/// Newline count within [range.start, range.end), plus one more if the
/// range's last byte isn't itself a newline (an unterminated final
/// line — only possible for the LAST worker's range, since every
/// earlier range's end was aligned to just-past-a-newline by
/// splitRanges(), but checked unconditionally here since it costs
/// nothing and doesn't rely on that invariant holding).
fn countRange(file: std.fs.File, range: Range) !usize {
    var buf: [WORKER_CHUNK_SIZE]u8 = undefined;
    var pos = range.start;
    var n: usize = 0;
    var saw_any_after_last_nl = false;
    while (pos < range.end) {
        const remaining: u64 = range.end - pos;
        const to_read: usize = @intCast(@min(@as(u64, buf.len), remaining));
        const read = try file.pread(buf[0..to_read], pos);
        if (read == 0) break;
        for (buf[0..read]) |c| {
            if (c == '\n') {
                n += 1;
                saw_any_after_last_nl = false;
            } else {
                saw_any_after_last_nl = true;
            }
        }
        pos += read;
    }
    if (saw_any_after_last_nl) n += 1;
    return n;
}

/// Total line count across the whole file (header included) — the
/// building block parallelCountRows() below subtracts 1 from. Not
/// exposed publicly: a real caller almost always wants the header-
/// excluded row count, same as Scanner.countRemaining()'s post-header
/// semantics.
fn parallelCountLines(allocator: Allocator, path: []const u8, num_threads_in: usize) !usize {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const file_size = (try file.stat()).size;
    if (file_size == 0) return 0;

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const requested = if (num_threads_in == 0) cpu_count else num_threads_in;
    // Never split into more pieces than there are bytes — a range needs
    // at least 1 byte to mean anything.
    const num_threads = @max(1, @min(requested, file_size));

    if (num_threads <= 1) {
        return countRange(file, .{ .start = 0, .end = file_size });
    }

    const ranges = try splitRanges(allocator, file, file_size, num_threads);
    defer allocator.free(ranges);

    const workers = try allocator.alloc(CountWorker, num_threads);
    defer allocator.free(workers);
    const threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    for (ranges, 0..) |r, i| workers[i] = .{ .file = file, .range = r };
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, countWorkerRun, .{&workers[i]});
    }
    for (threads) |t| t.join();

    var total: usize = 0;
    for (workers) |w| {
        if (w.err) |e| return e;
        total += w.result;
    }
    return total;
}

/// Sniffs line-delimited (CSV, NDJSON) vs JSON-array from the first
/// non-whitespace byte — same rule NdjsonScanner.openWithChunkSize()
/// uses (see ndjson.zig), reimplemented here via a single small pread()
/// instead of opening a full scanner just to read one byte. `.csv` is
/// returned for anything that isn't a JSON-array (both CSV and NDJSON
/// are one-record-per-line at the byte level, so they share the same
/// newline-counting path below — this function only needs to tell JSON
/// arrays apart from everything else).
const SniffedFormat = enum { line_delimited, json_array };

fn sniffFormat(file: std.fs.File, file_size: u64) !SniffedFormat {
    var buf: [256]u8 = undefined;
    const to_read: usize = @intCast(@min(@as(u64, buf.len), file_size));
    const n = try file.pread(buf[0..to_read], 0);
    for (buf[0..n]) |b| {
        if (b == ' ' or b == '\t' or b == '\n' or b == '\r') continue;
        return if (b == '[') .json_array else .line_delimited;
    }
    return .line_delimited; // all whitespace in the sniffed window — treat as the common case
}

/// Sequential (NOT parallel — see doc comment below) top-level object
/// count for a JSON-array file. Same brace-depth/in-string/escape state
/// machine as NdjsonScanner.nextObject() (ndjson.zig), reimplemented
/// here over raw pread() chunks instead of a scanner's buffer, since
/// this only needs a count, not materialized object text.
///
/// Why this isn't split across threads like the line-delimited path:
/// a JSON array's Nth object boundary can only be found by tracking
/// nesting depth from the START of the file — unlike a newline, which
/// is self-describing at any byte offset, "is this `}` a top-level
/// close or a nested one" depends on everything read so far. A correct
/// parallel split would need a sequential pre-pass to find aligned
/// boundaries anyway, and that pre-pass already IS the count (walking
/// depth to find N boundaries costs the same as walking depth to find
/// all of them) — so for bare counting specifically, splitting further
/// buys nothing. It would start paying off for parallel WHERE-filtered
/// scans or field extraction (the actually-expensive part per this
/// session's NDJSON work), where per-object work dwarfs the boundary
/// walk — not implemented here, out of scope for this slice.
fn countJsonArrayObjects(file: std.fs.File, file_size: u64) !usize {
    var buf: [WORKER_CHUNK_SIZE]u8 = undefined;
    var pos: u64 = 0;
    var count: usize = 0;
    var started = false;
    var depth: usize = 0;
    var in_string = false;
    var escape = false;

    while (pos < file_size) {
        const remaining: u64 = file_size - pos;
        const to_read: usize = @intCast(@min(@as(u64, buf.len), remaining));
        const n = try file.pread(buf[0..to_read], pos);
        if (n == 0) break;
        for (buf[0..n]) |c| {
            if (!started) {
                if (c == '{') {
                    started = true;
                    depth = 1;
                }
                continue;
            }
            if (in_string) {
                if (escape) {
                    escape = false;
                } else if (c == '\\') {
                    escape = true;
                } else if (c == '"') {
                    in_string = false;
                }
                continue;
            }
            if (c == '"') {
                in_string = true;
            } else if (c == '{') {
                depth += 1;
            } else if (c == '}') {
                depth -= 1;
                if (depth == 0) {
                    count += 1;
                    started = false;
                }
            }
        }
        pos += n;
    }
    return count;
}

/// Row count — parallel equivalent of Query.count()'s no-WHERE fast
/// path. `num_threads` == 0 means "use std.Thread.getCpuCount()".
/// Format is determined two ways, matching how the rest of libscanio
/// does it (query.zig's inferFormat(), same extension rule): CSV has a
/// header line that isn't a data row, NDJSON doesn't — get this wrong
/// and every NDJSON file undercounts by exactly one row, which a naive
/// "always subtract the header" version of this function did until a
/// correctness test caught it (`.ndjson` test fixtures have no header
/// line to subtract; CSV's does, and Scanner.open() already consumes it
/// before Scanner.countRemaining() is ever called — this function has
/// no Scanner instance, so it has to know which format it's counting,
/// not just assume CSV's rule applies everywhere). Content is ALSO
/// sniffed (not just extension) to catch JSON arrays specifically —
/// `.json` files can legitimately be either NDJSON-lines or a JSON
/// array, and a JSON array's record boundary is a balanced `{...}`, not
/// a newline; routing those through newline-counting would silently
/// miscount (over on a pretty-printed array, under on a minified one —
/// both covered by this file's own tests).
pub fn parallelCountRows(allocator: Allocator, path: []const u8, num_threads: usize) !usize {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const file_size = (try file.stat()).size;
    if (file_size == 0) return ParallelError.EmptyFile;

    if (try sniffFormat(file, file_size) == .json_array) {
        return countJsonArrayObjects(file, file_size);
    }

    const has_header = query_mod.inferFormat(path) == .csv;
    const total_lines = try parallelCountLines(allocator, path, num_threads);
    if (total_lines == 0) return ParallelError.EmptyFile;
    if (!has_header) return total_lines;
    return total_lines - 1;
}

test "parallelCountRows matches single-thread count on a small file" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_small.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n3,900\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.testing.expectEqual(@as(usize, 3), try parallelCountRows(allocator, path, 4));
    try std.testing.expectEqual(@as(usize, 3), try parallelCountRows(allocator, path, 1));
    try std.testing.expectEqual(@as(usize, 3), try parallelCountRows(allocator, path, 0));
}

test "parallelCountRows: no trailing newline still counts the last row" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_no_trailing_nl.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id\n1\n2\n3" });
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.testing.expectEqual(@as(usize, 3), try parallelCountRows(allocator, path, 4));
}

test "parallelCountRows: more threads requested than bytes in the file doesn't crash" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_tiny.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "a\n1\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.testing.expectEqual(@as(usize, 1), try parallelCountRows(allocator, path, 64));
}

test "parallelCountRows: empty file returns EmptyFile" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_empty.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "" });
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.testing.expectError(ParallelError.EmptyFile, parallelCountRows(allocator, path, 4));
}

test "parallelCountRows matches single-thread count on a real multi-chunk-boundary file" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_large.csv";

    var data: std.ArrayList(u8) = .{};
    defer data.deinit(allocator);
    try data.appendSlice(allocator, "id,name,amount\n");
    var i: usize = 0;
    while (i < 200_000) : (i += 1) {
        try data.writer(allocator).print("{d},row-{d},{d}\n", .{ i, i, i * 7 });
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data.items });
    defer std.fs.cwd().deleteFile(path) catch {};

    const scan = @import("root.zig");
    var single = try scan.Scanner.open(allocator, path);
    defer single.deinit();
    const single_count = try single.countRemaining();

    const parallel_count = try parallelCountRows(allocator, path, 8);
    try std.testing.expectEqual(single_count, parallel_count);
    try std.testing.expectEqual(@as(usize, 200_000), parallel_count);
}

test "parallelCountRows: NDJSON (line-delimited) matches NdjsonScanner.countRemaining()" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_ndjson.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"id":1,"city":"Austin"}
        \\{"id":2,"city":"Denver"}
        \\{"id":3,"city":"Boston"}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    const scan = @import("root.zig");
    var single = try scan.NdjsonScanner.open(allocator, path);
    defer single.deinit();
    const single_count = try single.countRemaining();

    const parallel_count = try parallelCountRows(allocator, path, 4);
    try std.testing.expectEqual(single_count, parallel_count);
    try std.testing.expectEqual(@as(usize, 3), parallel_count);
}

test "parallelCountRows: NDJSON on a real multi-chunk-boundary file matches single-thread" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_ndjson_large.ndjson";

    var data: std.ArrayList(u8) = .{};
    defer data.deinit(allocator);
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        try data.writer(allocator).print("{{\"id\":{d},\"name\":\"row-{d}\",\"amount\":{d}}}\n", .{ i, i, i * 7 });
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data.items });
    defer std.fs.cwd().deleteFile(path) catch {};

    const scan = @import("root.zig");
    var single = try scan.NdjsonScanner.open(allocator, path);
    defer single.deinit();
    const single_count = try single.countRemaining();

    const parallel_count = try parallelCountRows(allocator, path, 8);
    try std.testing.expectEqual(single_count, parallel_count);
    try std.testing.expectEqual(@as(usize, 100_000), parallel_count);
}

test "parallelCountRows: JSON array is NOT miscounted via newlines (pretty-printed, multi-line)" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_json_array_pretty.json";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\[
        \\  {
        \\    "id": 1,
        \\    "city": "Austin"
        \\  },
        \\  {
        \\    "id": 2,
        \\    "city": "Denver"
        \\  },
        \\  {
        \\    "id": 3,
        \\    "city": "Boston"
        \\  }
        \\]
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    // Naive newline counting would badly overcount this (13 lines, 3 objects) —
    // the whole point of sniffFormat()/countJsonArrayObjects() existing.
    try std.testing.expectEqual(@as(usize, 3), try parallelCountRows(allocator, path, 4));
}

test "parallelCountRows: JSON array minified onto one line still counts objects, not newlines" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_json_array_minified.json";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "[{\"id\":1},{\"id\":2},{\"id\":3},{\"id\":4}]" });
    defer std.fs.cwd().deleteFile(path) catch {};

    // Naive newline counting would badly undercount this (0 newlines, 4 objects).
    try std.testing.expectEqual(@as(usize, 4), try parallelCountRows(allocator, path, 4));
}

test "parallelCountRows: JSON array matches NdjsonScanner.countRemaining() on a real multi-chunk file" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_json_array_large.json";

    var data: std.ArrayList(u8) = .{};
    defer data.deinit(allocator);
    try data.appendSlice(allocator, "[");
    var i: usize = 0;
    while (i < 50_000) : (i += 1) {
        if (i > 0) try data.appendSlice(allocator, ",");
        try data.writer(allocator).print("{{\"id\":{d},\"name\":\"row-{d}, with a comma and \\\"quotes\\\"\",\"amount\":{d}}}", .{ i, i, i * 7 });
    }
    try data.appendSlice(allocator, "]");
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data.items });
    defer std.fs.cwd().deleteFile(path) catch {};

    const scan = @import("root.zig");
    var single = try scan.NdjsonScanner.open(allocator, path);
    defer single.deinit();
    const single_count = try single.countRemaining();

    const parallel_count = try parallelCountRows(allocator, path, 8);
    try std.testing.expectEqual(single_count, parallel_count);
    try std.testing.expectEqual(@as(usize, 50_000), parallel_count);
}
