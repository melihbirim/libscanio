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

/// Row count, header excluded — parallel equivalent of
/// Query.count()'s no-WHERE fast path. `num_threads` == 0 means "use
/// std.Thread.getCpuCount()". Correct for both CSV and NDJSON (both are
/// one-record-per-line; JSON arrays are NOT supported here yet — their
/// record boundary is a balanced `{...}`, not a newline, so line-count
/// splitting doesn't apply without more work).
pub fn parallelCountRows(allocator: Allocator, path: []const u8, num_threads: usize) !usize {
    const total_lines = try parallelCountLines(allocator, path, num_threads);
    if (total_lines == 0) return ParallelError.EmptyFile;
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
