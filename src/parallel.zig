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
const json_parser = @import("json_parser.zig");
const topk_mod = @import("topk.zig");
pub const OwnedRow = topk_mod.OwnedRow;
const simd_count = @import("simd_count.zig");

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
    return splitRangesFrom(allocator, file, 0, file_size, num_threads);
}

/// Same as splitRanges(), but the data region starts at `data_start`
/// instead of byte 0 — used to skip a CSV header line (already known,
/// by the caller, not to be a data row) without needing a second range-
/// list shape. `data_start` itself is NOT re-aligned (the caller is
/// responsible for it already being a valid line start — e.g. the
/// position returned by alignForwardToNewline(file, ..., 0, ...) for a
/// header line).
fn splitRangesFrom(allocator: Allocator, file: std.fs.File, data_start: u64, file_size: u64, num_threads: usize) ![]Range {
    const ranges = try allocator.alloc(Range, num_threads);
    errdefer allocator.free(ranges);
    const data_len = file_size - data_start;
    const approx_chunk = data_len / num_threads;
    var start: u64 = data_start;
    for (0..num_threads) |i| {
        const is_last = i == num_threads - 1;
        const end = if (is_last) file_size else try alignForwardToNewline(file, allocator, start + approx_chunk, file_size);
        ranges[i] = .{ .start = start, .end = end };
        start = end;
    }
    return ranges;
}

/// 1MB, not root.zig's 256KB single-thread default — measured, not
/// assumed: on a real 10.46GB/130M-row file, 256KB gave a WHERE-filtered
/// parallel count of ~3.4s/2.2s (before/after the stop_after_column fix
/// below); bumping to 1MB alone took the post-fix number to a stable
/// ~1.86-1.88s, edging ahead of csvql's own WHERE COUNT(*) (1.99s) on
/// the same file. 2MB measured faster still (~1.8-2.0s) but pushed peak
/// memory to ~27MB, within noise of csvql's 29.3MB — closing the speed
/// gap further that way would cost the memory-efficiency story this
/// whole parallel path exists for; 1MB (peak ~14.4MB, still ~2x below
/// csvql) was kept as the better tradeoff. Single-thread root.zig's
/// 256KB stays as-is — that number was tuned for ITS OWN workload
/// (Scanner.next()'s per-row field split, not a multi-threaded raw-byte
/// scan), not blindly copied here.
const WORKER_CHUNK_SIZE = 1024 * 1024;

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
    var last_byte: ?u8 = null;
    while (pos < range.end) {
        const remaining: u64 = range.end - pos;
        const to_read: usize = @intCast(@min(@as(u64, buf.len), remaining));
        const read = try file.pread(buf[0..to_read], pos);
        if (read == 0) break;
        n += simd_count.countByte(buf[0..read], '\n');
        last_byte = buf[read - 1];
        pos += read;
    }
    if (last_byte) |b| {
        if (b != '\n') n += 1;
    }
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

/// Shared brace-depth/in-string/escape state machine, used by both
/// countJsonArrayObjects() (sequential, no boundaries needed) and
/// findJsonArrayRanges() (records boundaries too) — same logic, one
/// copy, a callback per completed top-level object instead of two
/// slightly-drifting hand-written loops. Plain per-byte scalar scan —
/// two different vectorized versions of this were tried and measured
/// worse, not assumed worse: (1) a fixed-16-byte-chunk bitmask+@ctz scan
/// (the technique that fixed json_simd.zig's tokenizer) regressed
/// (3.06s -> 4.10s on a real 1M-object fixture) because structural chars
/// in real JSON objects land every ~10-20 bytes, so most searches
/// resolve inside the FIRST 16-byte chunk — the fixed-chunk setup cost
/// (compare/mask-build/@ctz) is paid without ever reaching the span
/// where a wider scan pays for itself, the same failure mode an earlier
/// ndjson.zig fast-path attempt hit. (2) Switching to 4 separate
/// std.mem.indexOfScalarPos calls (stdlib's own tiered SIMD, which DID
/// win for that earlier ndjson.zig case) was worse still — a genuine
/// quadratic blowup, not just slower: this fixture has zero backslashes
/// anywhere, so a `\` search from any position scans forward to the end
/// of the current ~1MB buffer EVERY time it's called, and it's called
/// on every structural hit (every ~15 bytes) — roughly (buffer_size /
/// 15) full-buffer scans per buffer, which never finished inside a 60s
/// timeout on the real fixture. Both attempts logged in ROADMAP.md as a
/// deliberate negative result, not silently dropped.
fn walkJsonArrayObjectCloses(
    file: std.fs.File,
    file_size: u64,
    comptime Ctx: type,
    ctx: *Ctx,
    comptime onClose: fn (*Ctx, u64) anyerror!void,
) !void {
    var buf: [WORKER_CHUNK_SIZE]u8 = undefined;
    var pos: u64 = 0;
    var started = false;
    var depth: usize = 0;
    var in_string = false;
    var escape = false;

    while (pos < file_size) {
        const remaining: u64 = file_size - pos;
        const to_read: usize = @intCast(@min(@as(u64, buf.len), remaining));
        const n = try file.pread(buf[0..to_read], pos);
        if (n == 0) break;
        for (buf[0..n], 0..) |c, off| {
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
                    started = false;
                    try onClose(ctx, pos + off + 1);
                }
            }
        }
        pos += n;
    }
}

/// Sequential (NOT parallel — see doc comment below) top-level object
/// count for a JSON-array file.
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
/// walk — that's exactly what findJsonArrayRanges() below is for.
fn countJsonArrayObjects(file: std.fs.File, file_size: u64) !usize {
    const CountCtx = struct { count: usize = 0 };
    const onClose = struct {
        fn f(c: *CountCtx, _: u64) !void {
            c.count += 1;
        }
    }.f;
    var ctx = CountCtx{};
    try walkJsonArrayObjectCloses(file, file_size, CountCtx, &ctx, onClose);
    return ctx.count;
}

/// Splits a JSON array's data region into up to `num_threads` disjoint,
/// OBJECT-boundary-aligned ranges — makes WHERE-filtered parallel work
/// possible, unlike countJsonArrayObjects() above (a bare count gets
/// nothing from splitting further, since finding the boundaries costs
/// the same as counting them; see that function's doc comment). The
/// difference here: the per-object PARSE + predicate-match work this
/// enables downstream is the expensive part (per this project's own
/// NDJSON investigation — json_parser.parseObject() is not the
/// optimized fast path), so paying a sequential O(file) boundary walk
/// once, up front, to unlock parallel parsing on top of it is a real
/// net win, not just moving the cost around.
///
/// Records a range boundary the first time a top-level object closes at
/// or past each `i * file_size/num_threads` target, so ranges are
/// roughly equal-sized without needing random access into the file
/// (which JSON's nesting makes impossible — depth at an arbitrary byte
/// offset depends on everything read before it).
fn findJsonArrayRanges(allocator: Allocator, file: std.fs.File, file_size: u64, num_threads: usize) ![]Range {
    const RangeCtx = struct {
        allocator: Allocator,
        ranges: std.ArrayListUnmanaged(Range) = .{},
        range_start: u64 = 0,
        next_target: u64,
        approx_chunk: u64,
        num_threads: usize,
    };
    const onClose = struct {
        fn f(c: *RangeCtx, end_pos: u64) !void {
            if (end_pos >= c.next_target and c.ranges.items.len + 1 < c.num_threads) {
                try c.ranges.append(c.allocator, .{ .start = c.range_start, .end = end_pos });
                c.range_start = end_pos;
                c.next_target = end_pos + c.approx_chunk;
            }
        }
    }.f;

    const approx_chunk = file_size / num_threads;
    var ctx = RangeCtx{ .allocator = allocator, .next_target = approx_chunk, .approx_chunk = approx_chunk, .num_threads = num_threads };
    errdefer ctx.ranges.deinit(allocator);
    try walkJsonArrayObjectCloses(file, file_size, RangeCtx, &ctx, onClose);
    try ctx.ranges.append(allocator, .{ .start = ctx.range_start, .end = file_size });
    return ctx.ranges.toOwnedSlice(allocator);
}

/// Walks every complete top-level JSON object in [range.start, range.end)
/// of `file`, calling `body(ctx, object_text)` once per object — same
/// chunk-boundary-carry shape as forEachLineInRange() (a `scratch` buffer
/// catches an object whose bytes span two pread() calls), except the
/// boundary being tracked is a balanced `{...}`, not a `\n`. Ranges from
/// findJsonArrayRanges() are guaranteed to start/end exactly between two
/// objects (or at file start/end), so this never begins or ends mid-object.
fn forEachJsonObjectInRange(
    allocator: Allocator,
    file: std.fs.File,
    range: Range,
    comptime Ctx: type,
    ctx: *Ctx,
    comptime body: fn (*Ctx, []const u8) anyerror!void,
) !void {
    var buf: [WORKER_CHUNK_SIZE]u8 = undefined;
    var buf_len: usize = 0;
    var buf_pos: usize = 0;
    var file_pos: u64 = range.start;
    var scratch: std.ArrayListUnmanaged(u8) = .{};
    defer scratch.deinit(allocator);

    while (true) {
        var started = false;
        var depth: usize = 0;
        var in_string = false;
        var escape = false;
        var obj_start: usize = buf_pos;
        scratch.clearRetainingCapacity();
        var found: ?[]const u8 = null;

        object_search: while (true) {
            while (buf_pos < buf_len) {
                const c = buf[buf_pos];
                if (!started) {
                    if (c == '{') {
                        started = true;
                        depth = 1;
                        obj_start = buf_pos;
                    }
                    buf_pos += 1;
                    continue;
                }
                buf_pos += 1;
                if (in_string) {
                    if (escape) {
                        escape = false;
                    } else if (c == '\\') {
                        escape = true;
                    } else if (c == '"') {
                        in_string = false;
                    }
                } else if (c == '"') {
                    in_string = true;
                } else if (c == '{') {
                    depth += 1;
                } else if (c == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        const chunk_part = buf[obj_start..buf_pos];
                        if (scratch.items.len == 0) {
                            found = chunk_part;
                        } else {
                            try scratch.appendSlice(allocator, chunk_part);
                            found = scratch.items;
                        }
                        break :object_search;
                    }
                }
            }
            // Buffer exhausted before a complete object was found —
            // flush what we have (if an object is in progress) and try
            // to read more, bounded by range.end.
            if (started) {
                try scratch.appendSlice(allocator, buf[obj_start..buf_pos]);
            }
            if (file_pos >= range.end) break :object_search; // no more data in this range
            const remaining: u64 = range.end - file_pos;
            const to_read: usize = @intCast(@min(@as(u64, buf.len), remaining));
            const n = try file.pread(buf[0..to_read], file_pos);
            if (n == 0) break :object_search;
            buf_len = n;
            buf_pos = 0;
            obj_start = 0;
            file_pos += n;
        }

        if (found) |obj| {
            try body(ctx, obj);
        } else {
            break;
        }
    }
}

/// Same "first record's keys become the header" rule buildNdjsonHeader()
/// uses for line-delimited files, but finds the first top-level `{...}`
/// object instead of the first line — JSON arrays have no newlines to
/// rely on. Grows its read window (same doubling strategy as
/// alignForwardToNewline()) only in the pathological case where the
/// first object alone is bigger than one chunk.
fn buildJsonArrayHeader(allocator: Allocator, file: std.fs.File, file_size: u64) !NdjsonHeader {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var window_size: usize = WORKER_CHUNK_SIZE;
    while (true) {
        const to_read: usize = @intCast(@min(@as(u64, window_size), file_size));
        const buf = try allocator.alloc(u8, to_read);
        defer allocator.free(buf);
        const n = try file.pread(buf, 0);

        var started = false;
        var depth: usize = 0;
        var in_string = false;
        var escape = false;
        var obj_start: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const c = buf[i];
            if (!started) {
                if (c == '{') {
                    started = true;
                    depth = 1;
                    obj_start = i;
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
                    const first_obj = try aa.dupe(u8, buf[obj_start .. i + 1]);
                    const obj = try json_parser.parseObject(first_obj, aa);
                    const header = try aa.alloc([]const u8, obj.fields.len);
                    var index: std.StringHashMapUnmanaged(usize) = .{};
                    try index.ensureTotalCapacity(aa, @intCast(obj.fields.len));
                    for (obj.fields, 0..) |field, k| {
                        header[k] = field.key;
                        index.putAssumeCapacity(field.key, k);
                    }
                    return .{ .header = header, .index = index, .arena = arena };
                }
            }
        }
        if (@as(u64, window_size) >= file_size) return error.MalformedJsonArray;
        window_size *= 2;
    }
}

const JsonArrayFilterCtx = struct {
    allocator: Allocator,
    header_index: *const std.StringHashMapUnmanaged(usize),
    predicates: []const query_mod.Predicate,
    field_buf: [][]const u8,
    arena: std.heap.ArenaAllocator,
    count: usize = 0,

    fn onObject(self: *JsonArrayFilterCtx, obj_text: []const u8) !void {
        _ = self.arena.reset(.retain_capacity);
        const obj = json_parser.parseObject(obj_text, self.arena.allocator()) catch return;
        for (self.field_buf) |*f| f.* = "";
        for (obj.fields) |field| {
            const idx = self.header_index.get(field.key) orelse continue;
            self.field_buf[idx] = renderJsonValue(field.value) catch continue;
        }
        const scan = @import("root.zig");
        if (query_mod.matches(scan.Row{ .fields = self.field_buf }, self.predicates)) self.count += 1;
    }
};

const JsonArrayFilterWorker = struct {
    allocator: Allocator,
    file: std.fs.File,
    range: Range,
    header: [][]const u8,
    header_index: *const std.StringHashMapUnmanaged(usize),
    predicates: []const query_mod.Predicate,
    result: usize = 0,
    err: ?anyerror = null,
};

fn jsonArrayFilterWorkerRun(w: *JsonArrayFilterWorker) void {
    const field_buf = w.allocator.alloc([]const u8, w.header.len) catch |e| {
        w.err = e;
        return;
    };
    var ctx = JsonArrayFilterCtx{
        .allocator = w.allocator,
        .header_index = w.header_index,
        .predicates = w.predicates,
        .field_buf = field_buf,
        .arena = std.heap.ArenaAllocator.init(w.allocator),
    };
    defer {
        ctx.arena.deinit();
        w.allocator.free(field_buf);
    }
    forEachJsonObjectInRange(w.allocator, w.file, w.range, JsonArrayFilterCtx, &ctx, JsonArrayFilterCtx.onObject) catch |e| {
        w.err = e;
        return;
    };
    w.result = ctx.count;
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

fn trimCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

/// Runs `body` (a per-line closure) over every complete line in
/// [range.start, range.end) of `file`, handling chunk-boundary carry the
/// same way Scanner.nextLine()/NdjsonScanner.nextLine() do (root.zig,
/// ndjson.zig) — a line that spans two pread() calls gets assembled into
/// `scratch` instead of lost or double-counted. Shared by the CSV and
/// NDJSON filtered-count workers below so that boundary-carry logic
/// exists in exactly one place, not copy-pasted per format.
fn forEachLineInRange(
    allocator: Allocator,
    file: std.fs.File,
    range: Range,
    comptime Ctx: type,
    ctx: *Ctx,
    comptime body: fn (*Ctx, []const u8) anyerror!void,
) !void {
    var buf: [WORKER_CHUNK_SIZE]u8 = undefined;
    var pos = range.start;
    var buf_len: usize = 0;
    var buf_pos: usize = 0;
    var scratch: std.ArrayListUnmanaged(u8) = .{};
    defer scratch.deinit(allocator);

    while (true) {
        if (buf_pos >= buf_len) {
            if (pos >= range.end) break;
            const remaining: u64 = range.end - pos;
            const to_read: usize = @intCast(@min(@as(u64, buf.len), remaining));
            const n = try file.pread(buf[0..to_read], pos);
            if (n == 0) break;
            buf_len = n;
            buf_pos = 0;
            pos += n;
        }
        const chunk = buf[buf_pos..buf_len];
        if (std.mem.indexOfScalar(u8, chunk, '\n')) |nl| {
            const line_part = chunk[0..nl];
            buf_pos += nl + 1;
            if (scratch.items.len == 0) {
                try body(ctx, trimCR(line_part));
            } else {
                try scratch.appendSlice(allocator, line_part);
                try body(ctx, trimCR(scratch.items));
                scratch.clearRetainingCapacity();
            }
        } else {
            try scratch.appendSlice(allocator, chunk);
            buf_pos = buf_len;
        }
    }
    // A trailing line with no terminator — only possible for the LAST
    // worker's range, since every earlier range's end was aligned to
    // just-past-a-newline by splitRangesFrom().
    if (scratch.items.len > 0) {
        try body(ctx, trimCR(scratch.items));
    }
}

/// Highest column index any predicate reads — same optimization root.zig's
/// Scanner already applies via ScannerOptions.stop_after_column, just
/// computed here from the predicate list directly instead of a caller-
/// supplied bound (this worker has no separate "columns" projection to
/// also account for, unlike Query, since a filtered COUNT never returns
/// row data). Real, measured motivation: without this, the CSV filter
/// worker split every column of every row (10, on the real e-commerce
/// fixture this was benchmarked against) even when the WHERE clause only
/// ever reads one — csvql's own WHERE-filtered COUNT(*) beat this
/// worker's un-bounded version (1.99s vs 3.37s on a real 130M-row file)
/// before this fix.
fn maxPredicateColumn(predicates: []const query_mod.Predicate) usize {
    var max: usize = 0;
    for (predicates) |p| max = @max(max, p.column);
    return max;
}

const CsvFilterCtx = struct {
    allocator: Allocator,
    delimiter: u8,
    predicates: []const query_mod.Predicate,
    stop_after_column: usize,
    field_buf: std.ArrayListUnmanaged([]const u8) = .{},
    count: usize = 0,

    fn deinit(self: *CsvFilterCtx) void {
        self.field_buf.deinit(self.allocator);
    }

    fn onLine(self: *CsvFilterCtx, line: []const u8) !void {
        self.field_buf.clearRetainingCapacity();
        var start: usize = 0;
        var i: usize = 0;
        while (i <= line.len) : (i += 1) {
            if (i == line.len or line[i] == self.delimiter) {
                try self.field_buf.append(self.allocator, line[start..i]);
                // Everything past stop_after_column is provably never
                // read by any predicate — stop splitting this row's
                // remaining bytes entirely, not just discard them.
                if (self.field_buf.items.len == self.stop_after_column + 1) break;
                start = i + 1;
            }
        }
        const scan = @import("root.zig");
        if (query_mod.matches(scan.Row{ .fields = self.field_buf.items }, self.predicates)) self.count += 1;
    }
};

const CsvFilterWorker = struct {
    allocator: Allocator,
    file: std.fs.File,
    range: Range,
    delimiter: u8,
    predicates: []const query_mod.Predicate,
    stop_after_column: usize,
    result: usize = 0,
    err: ?anyerror = null,
};

fn csvFilterWorkerRun(w: *CsvFilterWorker) void {
    var ctx = CsvFilterCtx{ .allocator = w.allocator, .delimiter = w.delimiter, .predicates = w.predicates, .stop_after_column = w.stop_after_column };
    defer ctx.deinit();
    forEachLineInRange(w.allocator, w.file, w.range, CsvFilterCtx, &ctx, CsvFilterCtx.onLine) catch |e| {
        w.err = e;
        return;
    };
    w.result = ctx.count;
}

/// NDJSON's WHERE-filtered worker context — parses each line with
/// json_parser.parseObject() (the simple, correct, allocating parser,
/// NOT ndjson.zig's optimized reuse/fast-path machinery) and maps
/// fields into a Row by `header_index` (name -> column index, built
/// ONCE from the file's first line and shared read-only across every
/// worker) so query_mod.matches() — which operates on numeric column
/// indices, same as the CSV path — works identically for both formats.
/// Correctness first: this is the same shape NdjsonScanner.next()
/// already uses (default every column to "", then overwrite only the
/// keys this row actually has), just without that file's speed work —
/// worth revisiting if parallel WHERE-filtered NDJSON scans turn out to
/// be parse-bound the way single-threaded ones were (see ROADMAP.md's
/// M4 entry).
const NdjsonFilterCtx = struct {
    allocator: Allocator,
    header: [][]const u8,
    header_index: *const std.StringHashMapUnmanaged(usize),
    predicates: []const query_mod.Predicate,
    field_buf: [][]const u8,
    arena: std.heap.ArenaAllocator,
    count: usize = 0,

    fn deinit(self: *NdjsonFilterCtx) void {
        self.arena.deinit();
        self.allocator.free(self.field_buf);
    }

    fn onLine(self: *NdjsonFilterCtx, line: []const u8) !void {
        if (line.len == 0) return; // blank trailing line, not a record
        _ = self.arena.reset(.retain_capacity);
        const obj = json_parser.parseObject(line, self.arena.allocator()) catch return; // malformed line: never matches, matches Query's own "no field, no match" behavior
        for (self.field_buf) |*f| f.* = "";
        for (obj.fields) |field| {
            const idx = self.header_index.get(field.key) orelse continue;
            self.field_buf[idx] = renderJsonValue(field.value) catch continue;
        }
        const scan = @import("root.zig");
        if (query_mod.matches(scan.Row{ .fields = self.field_buf }, self.predicates)) self.count += 1;
    }
};

fn renderJsonValue(val: json_parser.JsonValue) ![]const u8 {
    return switch (val) {
        .string => |s| s,
        .number => |s| s,
        .null_value => "",
        .bool_value => |b| if (b) "true" else "false",
        .array, .object => error.NestedValueNotSupported,
    };
}

const NdjsonFilterWorker = struct {
    allocator: Allocator,
    file: std.fs.File,
    range: Range,
    header: [][]const u8,
    header_index: *const std.StringHashMapUnmanaged(usize),
    predicates: []const query_mod.Predicate,
    result: usize = 0,
    err: ?anyerror = null,
};

fn ndjsonFilterWorkerRun(w: *NdjsonFilterWorker) void {
    const field_buf = w.allocator.alloc([]const u8, w.header.len) catch |e| {
        w.err = e;
        return;
    };
    var ctx = NdjsonFilterCtx{
        .allocator = w.allocator,
        .header = w.header,
        .header_index = w.header_index,
        .predicates = w.predicates,
        .field_buf = field_buf,
        .arena = std.heap.ArenaAllocator.init(w.allocator),
    };
    defer ctx.deinit();
    forEachLineInRange(w.allocator, w.file, w.range, NdjsonFilterCtx, &ctx, NdjsonFilterCtx.onLine) catch |e| {
        w.err = e;
        return;
    };
    w.result = ctx.count;
}

/// Builds header + header_index from an NDJSON file's first line — the
/// same "first row's keys, first-seen order, become the header" rule
/// NdjsonScanner.openWithChunkSize() uses (ndjson.zig), reimplemented
/// standalone here since this needs it BEFORE spawning any worker (every
/// worker shares one read-only header_index — building it per-worker
/// would be correct too, just wasted duplicate work on every thread for
/// data that's identical no matter which range computes it).
const NdjsonHeader = struct {
    header: [][]const u8,
    index: std.StringHashMapUnmanaged(usize),
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *NdjsonHeader) void {
        self.arena.deinit();
    }
};

fn buildNdjsonHeader(allocator: Allocator, file: std.fs.File, file_size: u64) !NdjsonHeader {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var buf: [WORKER_CHUNK_SIZE]u8 = undefined;
    const to_read: usize = @intCast(@min(@as(u64, buf.len), file_size));
    const n = try file.pread(buf[0..to_read], 0);
    const nl = std.mem.indexOfScalar(u8, buf[0..n], '\n') orelse n;
    // Duped into the arena, not a slice into the stack-local `buf` above —
    // json_parser.parseObject()'s unescaped-string fast path returns
    // zero-copy slices INTO WHATEVER BUFFER IT WAS GIVEN, and `buf` is
    // gone the instant this function returns. Real bug caught by the
    // filtered-count probe against real data: header_index's keys were
    // dangling pointers into a reused stack frame, so every lookup
    // silently failed, every NDJSON field defaulted to "", and every
    // WHERE clause evaluated false — a filtered parallel NDJSON count of
    // 0 on a file where the single-threaded Query.count() found
    // 1,000,000 matches, not caught by the small unit tests (which
    // happened not to exercise a header long/varied enough, or simply
    // got lucky with the reused stack bytes, to surface it) — only by
    // checking against the real wide fixture this session already had.
    const first_line = try aa.dupe(u8, trimCR(buf[0..nl]));

    const obj = try json_parser.parseObject(first_line, aa);
    var header = try aa.alloc([]const u8, obj.fields.len);
    var index: std.StringHashMapUnmanaged(usize) = .{};
    try index.ensureTotalCapacity(aa, @intCast(obj.fields.len));
    for (obj.fields, 0..) |field, i| {
        header[i] = field.key;
        index.putAssumeCapacity(field.key, i);
    }
    return .{ .header = header, .index = index, .arena = arena };
}

/// Row count with a WHERE clause applied per row — parallel equivalent
/// of Query.count()'s filtered (non-fast-path) branch. `predicates` use
/// the same query_mod.Predicate shape (numeric column index, not name —
/// resolve names via a throwaway Scanner/NdjsonScanner open first, same
/// as Query.open()/the Python/Node bindings already do). All three
/// formats now run genuinely in parallel: CSV and NDJSON split on line
/// boundaries (NDJSON via a shared, once-built header_index — see
/// buildNdjsonHeader()); JSON arrays split on OBJECT boundaries (see
/// findJsonArrayRanges()) — unlike the no-WHERE fast path
/// (parallelCountRows(), see countJsonArrayObjects()'s doc comment for
/// why THAT one stays sequential), the per-object parse+match work here
/// is expensive enough that paying a one-time sequential boundary walk
/// to unlock parallel parsing on top of it is a real net win, not just
/// moved cost.
pub fn parallelCountRowsWhere(
    allocator: Allocator,
    path: []const u8,
    delimiter: u8,
    predicates: []const query_mod.Predicate,
    num_threads_in: usize,
) !usize {
    if (predicates.len == 0) return parallelCountRows(allocator, path, num_threads_in);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const file_size = (try file.stat()).size;
    if (file_size == 0) return ParallelError.EmptyFile;

    if (try sniffFormat(file, file_size) == .json_array) {
        if (file_size == 0) return ParallelError.EmptyFile;
        const cpu_count = std.Thread.getCpuCount() catch 1;
        const requested = if (num_threads_in == 0) cpu_count else num_threads_in;
        const num_threads = @max(1, @min(requested, file_size));

        var hdr = try buildJsonArrayHeader(allocator, file, file_size);
        defer hdr.deinit();
        const ranges = try findJsonArrayRanges(allocator, file, file_size, num_threads);
        defer allocator.free(ranges);

        const workers = try allocator.alloc(JsonArrayFilterWorker, ranges.len);
        defer allocator.free(workers);
        const threads = try allocator.alloc(std.Thread, ranges.len);
        defer allocator.free(threads);
        for (ranges, 0..) |r, i| workers[i] = .{ .allocator = allocator, .file = file, .range = r, .header = hdr.header, .header_index = &hdr.index, .predicates = predicates };
        for (0..ranges.len) |i| threads[i] = try std.Thread.spawn(.{}, jsonArrayFilterWorkerRun, .{&workers[i]});
        for (threads) |t| t.join();

        var total: usize = 0;
        for (workers) |w| {
            if (w.err) |e| return e;
            total += w.result;
        }
        return total;
    }

    const is_csv = query_mod.inferFormat(path) == .csv;
    const data_start: u64 = if (is_csv) try alignForwardToNewline(file, allocator, 0, file_size) else 0;
    if (data_start >= file_size) return 0; // header-only file, no data rows

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const requested = if (num_threads_in == 0) cpu_count else num_threads_in;
    const data_len = file_size - data_start;
    const num_threads = @max(1, @min(requested, data_len));

    const ranges = try splitRangesFrom(allocator, file, data_start, file_size, num_threads);
    defer allocator.free(ranges);

    var total: usize = 0;
    if (is_csv) {
        const stop_after_column = maxPredicateColumn(predicates);
        const workers = try allocator.alloc(CsvFilterWorker, num_threads);
        defer allocator.free(workers);
        const threads = try allocator.alloc(std.Thread, num_threads);
        defer allocator.free(threads);
        for (ranges, 0..) |r, i| workers[i] = .{ .allocator = allocator, .file = file, .range = r, .delimiter = delimiter, .predicates = predicates, .stop_after_column = stop_after_column };
        for (0..num_threads) |i| threads[i] = try std.Thread.spawn(.{}, csvFilterWorkerRun, .{&workers[i]});
        for (threads) |t| t.join();
        for (workers) |w| {
            if (w.err) |e| return e;
            total += w.result;
        }
    } else {
        var hdr = try buildNdjsonHeader(allocator, file, file_size);
        defer hdr.deinit();
        const workers = try allocator.alloc(NdjsonFilterWorker, num_threads);
        defer allocator.free(workers);
        const threads = try allocator.alloc(std.Thread, num_threads);
        defer allocator.free(threads);
        for (ranges, 0..) |r, i| workers[i] = .{ .allocator = allocator, .file = file, .range = r, .header = hdr.header, .header_index = &hdr.index, .predicates = predicates };
        for (0..num_threads) |i| threads[i] = try std.Thread.spawn(.{}, ndjsonFilterWorkerRun, .{&workers[i]});
        for (threads) |t| t.join();
        for (workers) |w| {
            if (w.err) |e| return e;
            total += w.result;
        }
    }
    return total;
}

pub const ScannedRows = struct {
    allocator: Allocator,
    rows: []OwnedRow,

    pub fn deinit(self: ScannedRows) void {
        for (self.rows) |r| r.deinit();
        self.allocator.free(self.rows);
    }
};

const CsvScanCtx = struct {
    allocator: Allocator,
    delimiter: u8,
    predicates: []const query_mod.Predicate,
    field_buf: std.ArrayListUnmanaged([]const u8) = .{},
    rows: std.ArrayListUnmanaged(OwnedRow) = .{},

    fn onLine(self: *CsvScanCtx, line: []const u8) !void {
        self.field_buf.clearRetainingCapacity();
        var start: usize = 0;
        var i: usize = 0;
        while (i <= line.len) : (i += 1) {
            if (i == line.len or line[i] == self.delimiter) {
                try self.field_buf.append(self.allocator, line[start..i]);
                start = i + 1;
            }
        }
        const scan = @import("root.zig");
        const row = scan.Row{ .fields = self.field_buf.items };
        if (query_mod.matches(row, self.predicates)) {
            try self.rows.append(self.allocator, try topk_mod.copyRow(self.allocator, row));
        }
    }
};

const CsvScanWorker = struct {
    allocator: Allocator,
    file: std.fs.File,
    range: Range,
    delimiter: u8,
    predicates: []const query_mod.Predicate,
    rows: []OwnedRow = &.{},
    err: ?anyerror = null,
};

fn csvScanWorkerRun(w: *CsvScanWorker) void {
    var ctx = CsvScanCtx{ .allocator = w.allocator, .delimiter = w.delimiter, .predicates = w.predicates };
    defer ctx.field_buf.deinit(w.allocator);
    forEachLineInRange(w.allocator, w.file, w.range, CsvScanCtx, &ctx, CsvScanCtx.onLine) catch |e| {
        for (ctx.rows.items) |r| r.deinit();
        ctx.rows.deinit(w.allocator);
        w.err = e;
        return;
    };
    w.rows = ctx.rows.toOwnedSlice(w.allocator) catch |e| {
        for (ctx.rows.items) |r| r.deinit();
        ctx.rows.deinit(w.allocator);
        w.err = e;
        return;
    };
}

const NdjsonScanCtx = struct {
    allocator: Allocator,
    header_index: *const std.StringHashMapUnmanaged(usize),
    predicates: []const query_mod.Predicate,
    field_buf: [][]const u8,
    arena: std.heap.ArenaAllocator,
    rows: std.ArrayListUnmanaged(OwnedRow) = .{},

    fn onLine(self: *NdjsonScanCtx, line: []const u8) !void {
        if (line.len == 0) return;
        _ = self.arena.reset(.retain_capacity);
        const obj = json_parser.parseObject(line, self.arena.allocator()) catch return;
        for (self.field_buf) |*f| f.* = "";
        for (obj.fields) |field| {
            const idx = self.header_index.get(field.key) orelse continue;
            self.field_buf[idx] = renderJsonValue(field.value) catch continue;
        }
        const scan = @import("root.zig");
        const row = scan.Row{ .fields = self.field_buf };
        if (query_mod.matches(row, self.predicates)) {
            try self.rows.append(self.allocator, try topk_mod.copyRow(self.allocator, row));
        }
    }
};

const NdjsonScanWorker = struct {
    allocator: Allocator,
    file: std.fs.File,
    range: Range,
    header: [][]const u8,
    header_index: *const std.StringHashMapUnmanaged(usize),
    predicates: []const query_mod.Predicate,
    rows: []OwnedRow = &.{},
    err: ?anyerror = null,
};

fn ndjsonScanWorkerRun(w: *NdjsonScanWorker) void {
    const field_buf = w.allocator.alloc([]const u8, w.header.len) catch |e| {
        w.err = e;
        return;
    };
    var ctx = NdjsonScanCtx{
        .allocator = w.allocator,
        .header_index = w.header_index,
        .predicates = w.predicates,
        .field_buf = field_buf,
        .arena = std.heap.ArenaAllocator.init(w.allocator),
    };
    defer {
        ctx.arena.deinit();
        w.allocator.free(field_buf);
    }
    forEachLineInRange(w.allocator, w.file, w.range, NdjsonScanCtx, &ctx, NdjsonScanCtx.onLine) catch |e| {
        for (ctx.rows.items) |r| r.deinit();
        ctx.rows.deinit(w.allocator);
        w.err = e;
        return;
    };
    w.rows = ctx.rows.toOwnedSlice(w.allocator) catch |e| {
        for (ctx.rows.items) |r| r.deinit();
        ctx.rows.deinit(w.allocator);
        w.err = e;
        return;
    };
}

/// Materialized WHERE-filtered row scan — parallel equivalent of the
/// bindings' scanArray() (Python/Node), brought down into Zig core so
/// it's available to any consumer, not just those two. Same
/// CSV-parallel/NDJSON-parallel/JSON-array-delegates-to-Query split as
/// parallelCountRowsWhere() (see its doc comment for the JSON-array
/// reasoning), same OwnedRow-copying cost topK()/orderBy() already
/// accept (a matched row has to survive past the worker's own reused
/// line buffer). Result order: workers' rows concatenated in RANGE
/// order (worker 0's matches, then worker 1's, ...) — NOT a promised
/// global merge back to exact file order, a deliberate choice (asked,
/// not assumed) since most callers of a parallel bulk scan don't need
/// it and enforcing it would cost a real ordering pass for no benefit
/// to those callers. `predicates.len == 0` still filters nothing (scans
/// every row) — unlike parallelCountRowsWhere(), there's no cheaper
/// "fast path" available for the no-WHERE case here (every row has to
/// be materialized regardless), so no special-casing.
pub fn parallelScan(
    allocator: Allocator,
    path: []const u8,
    delimiter: u8,
    predicates: []const query_mod.Predicate,
    num_threads_in: usize,
) !ScannedRows {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const file_size = (try file.stat()).size;
    if (file_size == 0) return ParallelError.EmptyFile;

    if (try sniffFormat(file, file_size) == .json_array) {
        const scan = @import("root.zig");
        var q = try scan.Query.open(allocator, path, .{ .where = predicates, .format = .ndjson });
        defer q.deinit();
        var rows: std.ArrayListUnmanaged(OwnedRow) = .{};
        errdefer {
            for (rows.items) |r| r.deinit();
            rows.deinit(allocator);
        }
        while (try q.next()) |row| {
            try rows.append(allocator, try topk_mod.copyRow(allocator, row));
        }
        return .{ .allocator = allocator, .rows = try rows.toOwnedSlice(allocator) };
    }

    const is_csv = query_mod.inferFormat(path) == .csv;
    const data_start: u64 = if (is_csv) try alignForwardToNewline(file, allocator, 0, file_size) else 0;
    if (data_start >= file_size) return .{ .allocator = allocator, .rows = &.{} };

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const requested = if (num_threads_in == 0) cpu_count else num_threads_in;
    const data_len = file_size - data_start;
    const num_threads = @max(1, @min(requested, data_len));

    const ranges = try splitRangesFrom(allocator, file, data_start, file_size, num_threads);
    defer allocator.free(ranges);

    var total_rows: std.ArrayListUnmanaged(OwnedRow) = .{};
    errdefer {
        for (total_rows.items) |r| r.deinit();
        total_rows.deinit(allocator);
    }

    if (is_csv) {
        const workers = try allocator.alloc(CsvScanWorker, num_threads);
        defer allocator.free(workers);
        const threads = try allocator.alloc(std.Thread, num_threads);
        defer allocator.free(threads);
        for (ranges, 0..) |r, i| workers[i] = .{ .allocator = allocator, .file = file, .range = r, .delimiter = delimiter, .predicates = predicates };
        for (0..num_threads) |i| threads[i] = try std.Thread.spawn(.{}, csvScanWorkerRun, .{&workers[i]});
        for (threads) |t| t.join();

        var first_err: ?anyerror = null;
        for (workers) |w| {
            if (w.err) |e| first_err = e;
        }
        if (first_err) |e| {
            for (workers) |w| {
                for (w.rows) |r| r.deinit();
                if (w.rows.len > 0) allocator.free(w.rows);
            }
            return e;
        }
        for (workers) |w| {
            try total_rows.appendSlice(allocator, w.rows);
            if (w.rows.len > 0) allocator.free(w.rows);
        }
    } else {
        var hdr = try buildNdjsonHeader(allocator, file, file_size);
        defer hdr.deinit();
        const workers = try allocator.alloc(NdjsonScanWorker, num_threads);
        defer allocator.free(workers);
        const threads = try allocator.alloc(std.Thread, num_threads);
        defer allocator.free(threads);
        for (ranges, 0..) |r, i| workers[i] = .{ .allocator = allocator, .file = file, .range = r, .header = hdr.header, .header_index = &hdr.index, .predicates = predicates };
        for (0..num_threads) |i| threads[i] = try std.Thread.spawn(.{}, ndjsonScanWorkerRun, .{&workers[i]});
        for (threads) |t| t.join();

        var first_err: ?anyerror = null;
        for (workers) |w| {
            if (w.err) |e| first_err = e;
        }
        if (first_err) |e| {
            for (workers) |w| {
                for (w.rows) |r| r.deinit();
                if (w.rows.len > 0) allocator.free(w.rows);
            }
            return e;
        }
        for (workers) |w| {
            try total_rows.appendSlice(allocator, w.rows);
            if (w.rows.len > 0) allocator.free(w.rows);
        }
    }

    return .{ .allocator = allocator, .rows = try total_rows.toOwnedSlice(allocator) };
}

/// Per-column buffer pair — a concatenated `data` byte buffer plus a
/// `u32` `offsets` array (offsets[i]..offsets[i+1] bounds row i's
/// value), exactly Apache Arrow's own StringArray layout. Shared,
/// public type: c_api.zig's C ABI wraps this directly (no re-copy) for
/// scanio_parallel_collect_columnar() — see that function's doc comment
/// for why this exists instead of routing through parallelScan()'s
/// OwnedRow.
pub const ColumnBuf = struct {
    data: std.ArrayListUnmanaged(u8) = .{},
    offsets: std.ArrayListUnmanaged(u32) = .{},

    pub fn deinit(self: *ColumnBuf, allocator: Allocator) void {
        self.data.deinit(allocator);
        self.offsets.deinit(allocator);
    }
};

pub const ColumnarScanResult = struct {
    allocator: Allocator,
    columns: []ColumnBuf,
    n_rows: usize,
    n_cols: usize,

    pub fn deinit(self: *ColumnarScanResult) void {
        for (self.columns) |*c| c.deinit(self.allocator);
        if (self.columns.len > 0) self.allocator.free(self.columns);
    }
};

fn newColumnBufs(allocator: Allocator, n_cols: usize) ![]ColumnBuf {
    const columns = try allocator.alloc(ColumnBuf, n_cols);
    for (columns) |*c| c.* = .{};
    for (columns) |*c| try c.offsets.append(allocator, 0);
    return columns;
}

fn deinitColumnBufs(allocator: Allocator, columns: []ColumnBuf) void {
    for (columns) |*c| c.deinit(allocator);
    if (columns.len > 0) allocator.free(columns);
}

const CsvScanColumnarCtx = struct {
    allocator: Allocator,
    delimiter: u8,
    predicates: []const query_mod.Predicate,
    field_buf: std.ArrayListUnmanaged([]const u8) = .{},
    columns: []ColumnBuf,
    n_rows: usize = 0,

    fn onLine(self: *CsvScanColumnarCtx, line: []const u8) !void {
        self.field_buf.clearRetainingCapacity();
        var start: usize = 0;
        var i: usize = 0;
        while (i <= line.len) : (i += 1) {
            if (i == line.len or line[i] == self.delimiter) {
                try self.field_buf.append(self.allocator, line[start..i]);
                start = i + 1;
            }
        }
        const scan = @import("root.zig");
        const row = scan.Row{ .fields = self.field_buf.items };
        if (!query_mod.matches(row, self.predicates)) return;
        for (self.field_buf.items, 0..) |field, ci| {
            if (ci >= self.columns.len) break; // wider row than the header — extra trailing fields ignored, same as row-major collect()
            try self.columns[ci].data.appendSlice(self.allocator, field);
            try self.columns[ci].offsets.append(self.allocator, @intCast(self.columns[ci].data.items.len));
        }
        self.n_rows += 1;
    }
};

const CsvScanColumnarWorker = struct {
    allocator: Allocator,
    file: std.fs.File,
    range: Range,
    delimiter: u8,
    predicates: []const query_mod.Predicate,
    n_cols: usize,
    columns: []ColumnBuf = &.{},
    n_rows: usize = 0,
    err: ?anyerror = null,
};

fn csvScanColumnarWorkerRun(w: *CsvScanColumnarWorker) void {
    const columns = newColumnBufs(w.allocator, w.n_cols) catch |e| {
        w.err = e;
        return;
    };
    var ctx = CsvScanColumnarCtx{ .allocator = w.allocator, .delimiter = w.delimiter, .predicates = w.predicates, .columns = columns };
    defer ctx.field_buf.deinit(w.allocator);
    forEachLineInRange(w.allocator, w.file, w.range, CsvScanColumnarCtx, &ctx, CsvScanColumnarCtx.onLine) catch |e| {
        deinitColumnBufs(w.allocator, columns);
        w.err = e;
        return;
    };
    w.columns = columns;
    w.n_rows = ctx.n_rows;
}

const NdjsonScanColumnarCtx = struct {
    allocator: Allocator,
    header_index: *const std.StringHashMapUnmanaged(usize),
    predicates: []const query_mod.Predicate,
    field_buf: [][]const u8,
    arena: std.heap.ArenaAllocator,
    columns: []ColumnBuf,
    n_rows: usize = 0,

    fn onLine(self: *NdjsonScanColumnarCtx, line: []const u8) !void {
        if (line.len == 0) return;
        _ = self.arena.reset(.retain_capacity);
        const obj = json_parser.parseObject(line, self.arena.allocator()) catch return;
        for (self.field_buf) |*f| f.* = "";
        for (obj.fields) |field| {
            const idx = self.header_index.get(field.key) orelse continue;
            self.field_buf[idx] = renderJsonValue(field.value) catch continue;
        }
        const scan = @import("root.zig");
        const row = scan.Row{ .fields = self.field_buf };
        if (!query_mod.matches(row, self.predicates)) return;
        for (self.field_buf, 0..) |field, ci| {
            try self.columns[ci].data.appendSlice(self.allocator, field);
            try self.columns[ci].offsets.append(self.allocator, @intCast(self.columns[ci].data.items.len));
        }
        self.n_rows += 1;
    }
};

const NdjsonScanColumnarWorker = struct {
    allocator: Allocator,
    file: std.fs.File,
    range: Range,
    header: [][]const u8,
    header_index: *const std.StringHashMapUnmanaged(usize),
    predicates: []const query_mod.Predicate,
    columns: []ColumnBuf = &.{},
    n_rows: usize = 0,
    err: ?anyerror = null,
};

fn ndjsonScanColumnarWorkerRun(w: *NdjsonScanColumnarWorker) void {
    const field_buf = w.allocator.alloc([]const u8, w.header.len) catch |e| {
        w.err = e;
        return;
    };
    defer w.allocator.free(field_buf);
    const columns = newColumnBufs(w.allocator, w.header.len) catch |e| {
        w.err = e;
        return;
    };
    var ctx = NdjsonScanColumnarCtx{
        .allocator = w.allocator,
        .header_index = w.header_index,
        .predicates = w.predicates,
        .field_buf = field_buf,
        .arena = std.heap.ArenaAllocator.init(w.allocator),
        .columns = columns,
    };
    defer ctx.arena.deinit();
    forEachLineInRange(w.allocator, w.file, w.range, NdjsonScanColumnarCtx, &ctx, NdjsonScanColumnarCtx.onLine) catch |e| {
        deinitColumnBufs(w.allocator, columns);
        w.err = e;
        return;
    };
    w.columns = columns;
    w.n_rows = ctx.n_rows;
}

/// Merges N workers' per-worker ColumnBuf arrays into one final result —
/// one bulk `appendSlice` per worker per column for `data` (cheap, a
/// single memcpy-shaped operation, not per-field), one re-based integer
/// append per ROW for `offsets` (n_rows total across all workers, not
/// n_rows*n_cols). Still technically "two copies" of the bytes (worker-
/// local buffer, then this merge), but the DOMINANT cost this whole fix
/// exists for — OwnedRow's one-`allocator.dupe()`-per-FIELD pattern,
/// millions of tiny allocations for a large result — is gone; workers
/// only ever do amortized ArrayList growth, never per-field mallocs.
/// A further step (workers writing directly into a single shared, pre-
/// sized final buffer, avoiding this merge copy too) would need a
/// two-pass-per-worker approach — a real, larger change (see
/// scan_bench.zig's own two-pass fix for the same idea at smaller
/// scope) not pursued here since the actual measured cost driver was
/// the many-small-allocations pattern, not this merge step.
/// Frees each worker's ColumnBuf array right after its data is copied into
/// `final_columns`, instead of the caller holding every worker's buffers
/// alive until this whole function returns (Zig's `defer` in the caller
/// would otherwise keep ALL of them allocated simultaneously with the
/// growing final buffer — a real, measured near-2x transient memory peak
/// during merge, found by comparing libscanio's actual peak RSS against
/// pyarrow.dataset's on the same query: libscanio's RESULT data was
/// comparable in size, but its peak RSS was far higher, and this was why).
/// `workers` is consumed: every worker's ColumnBuf is deinitialized by the
/// time this returns, success or error.
fn mergeColumnarWorkers(allocator: Allocator, n_cols: usize, comptime WorkerT: type, workers: []WorkerT) !ColumnarScanResult {
    const final_columns = try newColumnBufs(allocator, n_cols);
    errdefer deinitColumnBufs(allocator, final_columns);
    errdefer for (workers) |*w| deinitColumnBufs(allocator, w.columns);

    var total_rows: usize = 0;
    for (workers) |*w| {
        for (0..n_cols) |ci| {
            const base: u32 = @intCast(final_columns[ci].data.items.len);
            try final_columns[ci].data.appendSlice(allocator, w.columns[ci].data.items);
            for (w.columns[ci].offsets.items[1..]) |off| {
                try final_columns[ci].offsets.append(allocator, base + off);
            }
        }
        total_rows += w.n_rows;
        deinitColumnBufs(allocator, w.columns);
    }
    return .{ .allocator = allocator, .columns = final_columns, .n_rows = total_rows, .n_cols = n_cols };
}

/// Columnar equivalent of parallelScan() — same range-splitting/thread
/// shape, but workers write directly into per-worker ColumnBuf arrays
/// (see mergeColumnarWorkers()'s doc comment for why this exists: it's
/// the real fix for a known, logged inefficiency — scanio_parallel_
/// collect_columnar() used to build parallelScan()'s OwnedRow results
/// first, THEN re-copy them into columnar buffers, paying both
/// OwnedRow's per-field-allocation cost AND a second full copy). JSON
/// arrays still delegate to the single-threaded Query path (same
/// reasoning as parallelScan()/parallelCountRowsWhere() — see their own
/// doc comments), but even there this builds columnar output directly
/// from Query.next(), no OwnedRow intermediate either.
pub fn parallelScanColumnar(
    allocator: Allocator,
    path: []const u8,
    delimiter: u8,
    predicates: []const query_mod.Predicate,
    num_threads_in: usize,
) !ColumnarScanResult {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const file_size = (try file.stat()).size;
    if (file_size == 0) return ParallelError.EmptyFile;

    if (try sniffFormat(file, file_size) == .json_array) {
        const scan = @import("root.zig");
        var q = try scan.Query.open(allocator, path, .{ .where = predicates, .format = .ndjson });
        defer q.deinit();
        const n_cols = q.header().len;
        const columns = try newColumnBufs(allocator, n_cols);
        errdefer deinitColumnBufs(allocator, columns);
        var n_rows: usize = 0;
        while (try q.next()) |row| {
            for (row.fields, 0..) |field, ci| {
                try columns[ci].data.appendSlice(allocator, field);
                try columns[ci].offsets.append(allocator, @intCast(columns[ci].data.items.len));
            }
            n_rows += 1;
        }
        return .{ .allocator = allocator, .columns = columns, .n_rows = n_rows, .n_cols = n_cols };
    }

    const is_csv = query_mod.inferFormat(path) == .csv;
    const data_start: u64 = if (is_csv) try alignForwardToNewline(file, allocator, 0, file_size) else 0;
    if (data_start >= file_size) {
        const columns = try newColumnBufs(allocator, 0);
        return .{ .allocator = allocator, .columns = columns, .n_rows = 0, .n_cols = 0 };
    }

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const requested = if (num_threads_in == 0) cpu_count else num_threads_in;
    const data_len = file_size - data_start;
    const num_threads = @max(1, @min(requested, data_len));

    const ranges = try splitRangesFrom(allocator, file, data_start, file_size, num_threads);
    defer allocator.free(ranges);

    if (is_csv) {
        var probe = try (@import("root.zig")).Scanner.open(allocator, path);
        const n_cols = probe.header.len;
        probe.deinit();

        const workers = try allocator.alloc(CsvScanColumnarWorker, num_threads);
        defer allocator.free(workers);
        const threads = try allocator.alloc(std.Thread, num_threads);
        defer allocator.free(threads);
        for (ranges, 0..) |r, i| workers[i] = .{ .allocator = allocator, .file = file, .range = r, .delimiter = delimiter, .predicates = predicates, .n_cols = n_cols };
        for (0..num_threads) |i| threads[i] = try std.Thread.spawn(.{}, csvScanColumnarWorkerRun, .{&workers[i]});
        for (threads) |t| t.join();

        var first_err: ?anyerror = null;
        for (workers) |w| {
            if (w.err) |e| first_err = e;
        }
        if (first_err) |e| {
            for (workers) |w| deinitColumnBufs(allocator, w.columns);
            return e;
        }
        return mergeColumnarWorkers(allocator, n_cols, CsvScanColumnarWorker, workers);
    } else {
        var hdr = try buildNdjsonHeader(allocator, file, file_size);
        defer hdr.deinit();
        const n_cols = hdr.header.len;

        const workers = try allocator.alloc(NdjsonScanColumnarWorker, num_threads);
        defer allocator.free(workers);
        const threads = try allocator.alloc(std.Thread, num_threads);
        defer allocator.free(threads);
        for (ranges, 0..) |r, i| workers[i] = .{ .allocator = allocator, .file = file, .range = r, .header = hdr.header, .header_index = &hdr.index, .predicates = predicates };
        for (0..num_threads) |i| threads[i] = try std.Thread.spawn(.{}, ndjsonScanColumnarWorkerRun, .{&workers[i]});
        for (threads) |t| t.join();

        var first_err: ?anyerror = null;
        for (workers) |w| {
            if (w.err) |e| first_err = e;
        }
        if (first_err) |e| {
            for (workers) |w| deinitColumnBufs(allocator, w.columns);
            return e;
        }
        return mergeColumnarWorkers(allocator, n_cols, NdjsonScanColumnarWorker, workers);
    }
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

test "parallelCountRowsWhere: CSV, single numeric predicate matches Query.count()" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_where_csv.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n3,900\n4,2500\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const scan = @import("root.zig");
    var q = try scan.Query.open(allocator, path, .{ .where = &.{query_mod.Predicate.init(1, .gt, "1000")} });
    defer q.deinit();
    const single_count = try q.count();

    const predicates = [_]query_mod.Predicate{query_mod.Predicate.init(1, .gt, "1000")};
    const parallel_count = try parallelCountRowsWhere(allocator, path, ',', &predicates, 4);
    try std.testing.expectEqual(single_count, parallel_count);
    try std.testing.expectEqual(@as(usize, 2), parallel_count);
}

test "parallelCountRowsWhere: CSV, no predicates falls back to the fast path" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_where_csv_empty.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id\n1\n2\n3\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.testing.expectEqual(@as(usize, 3), try parallelCountRowsWhere(allocator, path, ',', &.{}, 4));
}

test "parallelCountRowsWhere: CSV, AND of two predicates matches Query.count() on a real multi-chunk file" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_where_csv_large.csv";

    var data: std.ArrayList(u8) = .{};
    defer data.deinit(allocator);
    try data.appendSlice(allocator, "id,city,amount\n");
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        const city = if (i % 3 == 0) "Austin" else "Denver";
        try data.writer(allocator).print("{d},{s},{d}\n", .{ i, city, i * 3 });
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data.items });
    defer std.fs.cwd().deleteFile(path) catch {};

    const scan = @import("root.zig");
    var q = try scan.Query.open(allocator, path, .{ .where = &.{
        query_mod.Predicate.init(1, .eq, "Austin"),
        query_mod.Predicate.init(2, .gt, "100000"),
    } });
    defer q.deinit();
    const single_count = try q.count();

    const predicates = [_]query_mod.Predicate{
        query_mod.Predicate.init(1, .eq, "Austin"),
        query_mod.Predicate.init(2, .gt, "100000"),
    };
    const parallel_count = try parallelCountRowsWhere(allocator, path, ',', &predicates, 8);
    try std.testing.expectEqual(single_count, parallel_count);
}

test "parallelCountRowsWhere: NDJSON, single predicate matches Query.count()" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_where_ndjson.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"id":1,"city":"Austin","amount":50}
        \\{"id":2,"city":"Austin","amount":1500}
        \\{"id":3,"city":"Denver","amount":2500}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    const scan = @import("root.zig");
    var q = try scan.Query.open(allocator, path, .{ .where = &.{query_mod.Predicate.init(2, .gt, "1000")} });
    defer q.deinit();
    const single_count = try q.count();

    const predicates = [_]query_mod.Predicate{query_mod.Predicate.init(2, .gt, "1000")};
    const parallel_count = try parallelCountRowsWhere(allocator, path, ',', &predicates, 4);
    try std.testing.expectEqual(single_count, parallel_count);
    try std.testing.expectEqual(@as(usize, 2), parallel_count);
}

test "parallelCountRowsWhere: NDJSON, real multi-chunk file matches Query.count()" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_where_ndjson_large.ndjson";

    var data: std.ArrayList(u8) = .{};
    defer data.deinit(allocator);
    var i: usize = 0;
    while (i < 80_000) : (i += 1) {
        const city = if (i % 4 == 0) "Austin" else "Denver";
        try data.writer(allocator).print("{{\"id\":{d},\"city\":\"{s}\",\"amount\":{d}}}\n", .{ i, city, i * 3 });
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data.items });
    defer std.fs.cwd().deleteFile(path) catch {};

    const scan = @import("root.zig");
    var q = try scan.Query.open(allocator, path, .{ .where = &.{query_mod.Predicate.init(1, .eq, "Austin")} });
    defer q.deinit();
    const single_count = try q.count();

    const predicates = [_]query_mod.Predicate{query_mod.Predicate.init(1, .eq, "Austin")};
    const parallel_count = try parallelCountRowsWhere(allocator, path, ',', &predicates, 8);
    try std.testing.expectEqual(single_count, parallel_count);
    try std.testing.expectEqual(@as(usize, 20_000), parallel_count);
}

test "parallelCountRowsWhere: JSON array, single predicate matches Query.count()" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_where_json_array.json";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "[{\"id\":1,\"amount\":50},{\"id\":2,\"amount\":1500},{\"id\":3,\"amount\":2500}]" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const scan = @import("root.zig");
    var q = try scan.Query.open(allocator, path, .{ .where = &.{query_mod.Predicate.init(1, .gt, "1000")} });
    defer q.deinit();
    const single_count = try q.count();

    const predicates = [_]query_mod.Predicate{query_mod.Predicate.init(1, .gt, "1000")};
    const parallel_count = try parallelCountRowsWhere(allocator, path, ',', &predicates, 4);
    try std.testing.expectEqual(single_count, parallel_count);
    try std.testing.expectEqual(@as(usize, 2), parallel_count);
}

test "parallelCountRowsWhere: JSON array, pretty-printed multi-line still filters correctly" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_where_json_array_pretty.json";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\[
        \\  {"id": 1, "city": "Austin", "amount": 50},
        \\  {"id": 2, "city": "Denver", "amount": 3000},
        \\  {"id": 3, "city": "Austin", "amount": 1500}
        \\]
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    const predicates = [_]query_mod.Predicate{query_mod.Predicate.init(1, .eq, "Austin")};
    try std.testing.expectEqual(@as(usize, 2), try parallelCountRowsWhere(allocator, path, ',', &predicates, 4));
}

test "parallelScan: CSV, single-threaded returns matching rows with full field data" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_scan_csv.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,city,amount\n1,Austin,50\n2,Denver,1500\n3,Austin,900\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const predicates = [_]query_mod.Predicate{query_mod.Predicate.init(1, .eq, "Austin")};
    var result = try parallelScan(allocator, path, ',', &predicates, 1);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.rows.len);
    try std.testing.expectEqualStrings("1", result.rows[0].get(0).?);
    try std.testing.expectEqualStrings("Austin", result.rows[0].get(1).?);
    try std.testing.expectEqualStrings("50", result.rows[0].get(2).?);
    try std.testing.expectEqualStrings("3", result.rows[1].get(0).?);
}

test "parallelScan: CSV, no predicates returns every row" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_scan_csv_all.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id\n1\n2\n3\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var result = try parallelScan(allocator, path, ',', &.{}, 4);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.rows.len);
}

test "parallelScan: CSV, real multi-chunk file — result set matches Query.count(), every row's own fields are internally consistent" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_scan_csv_large.csv";

    var data: std.ArrayList(u8) = .{};
    defer data.deinit(allocator);
    try data.appendSlice(allocator, "id,city,amount\n");
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        const city = if (i % 3 == 0) "Austin" else "Denver";
        try data.writer(allocator).print("{d},{s},{d}\n", .{ i, city, i * 3 });
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data.items });
    defer std.fs.cwd().deleteFile(path) catch {};

    const scan = @import("root.zig");
    var q = try scan.Query.open(allocator, path, .{ .where = &.{scan.Predicate.init(1, .eq, "Austin")} });
    defer q.deinit();
    const expected_count = try q.count();

    const predicates = [_]query_mod.Predicate{query_mod.Predicate.init(1, .eq, "Austin")};
    var result = try parallelScan(allocator, path, ',', &predicates, 8);
    defer result.deinit();

    try std.testing.expectEqual(expected_count, result.rows.len);
    // Every returned row's own id/city/amount fields must be mutually
    // consistent (amount == id*3, city == "Austin") — catches a wrong
    // field_buf/header mapping even if the COUNT happens to be right.
    for (result.rows) |row| {
        try std.testing.expectEqualStrings("Austin", row.get(1).?);
        const id = try std.fmt.parseInt(usize, row.get(0).?, 10);
        const amount = try std.fmt.parseInt(usize, row.get(2).?, 10);
        try std.testing.expectEqual(id * 3, amount);
    }
}

test "parallelScan: NDJSON matches Query result set, fields internally consistent" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_scan_ndjson.ndjson";

    var data: std.ArrayList(u8) = .{};
    defer data.deinit(allocator);
    var i: usize = 0;
    while (i < 50_000) : (i += 1) {
        const city = if (i % 4 == 0) "Austin" else "Denver";
        try data.writer(allocator).print("{{\"id\":{d},\"city\":\"{s}\",\"amount\":{d}}}\n", .{ i, city, i * 5 });
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data.items });
    defer std.fs.cwd().deleteFile(path) catch {};

    const scan = @import("root.zig");
    var q = try scan.Query.open(allocator, path, .{ .where = &.{scan.Predicate.init(1, .eq, "Austin")} });
    defer q.deinit();
    const expected_count = try q.count();

    const predicates = [_]query_mod.Predicate{query_mod.Predicate.init(1, .eq, "Austin")};
    var result = try parallelScan(allocator, path, ',', &predicates, 8);
    defer result.deinit();

    try std.testing.expectEqual(expected_count, result.rows.len);
    for (result.rows) |row| {
        try std.testing.expectEqualStrings("Austin", row.get(1).?);
        const id = try std.fmt.parseInt(usize, row.get(0).?, 10);
        const amount = try std.fmt.parseInt(usize, row.get(2).?, 10);
        try std.testing.expectEqual(id * 5, amount);
    }
}

test "parallelScan: JSON array matches Query result set" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_scan_json_array.json";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "[{\"id\":1,\"city\":\"Austin\"},{\"id\":2,\"city\":\"Denver\"},{\"id\":3,\"city\":\"Austin\"}]" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const predicates = [_]query_mod.Predicate{query_mod.Predicate.init(1, .eq, "Austin")};
    var result = try parallelScan(allocator, path, ',', &predicates, 4);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.rows.len);
}

test "parallelScan: empty file returns EmptyFile" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_scan_empty.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "" });
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.testing.expectError(ParallelError.EmptyFile, parallelScan(allocator, path, ',', &.{}, 4));
}

fn columnarCellValue(result: ColumnarScanResult, col: usize, row: usize) []const u8 {
    const c = result.columns[col];
    return c.data.items[c.offsets.items[row]..c.offsets.items[row + 1]];
}

test "parallelScanColumnar: CSV matches parallelScan's OwnedRow output on a real multi-chunk file" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_columnar_csv.csv";

    var data: std.ArrayList(u8) = .{};
    defer data.deinit(allocator);
    try data.appendSlice(allocator, "id,city,amount\n");
    var i: usize = 0;
    while (i < 50_000) : (i += 1) {
        const city = if (i % 3 == 0) "Austin" else "Denver";
        try data.writer(allocator).print("{d},{s},{d}\n", .{ i, city, i * 3 });
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data.items });
    defer std.fs.cwd().deleteFile(path) catch {};

    const predicates = [_]query_mod.Predicate{query_mod.Predicate.init(1, .eq, "Austin")};

    var rowResult = try parallelScan(allocator, path, ',', &predicates, 8);
    defer rowResult.deinit();

    var colResult = try parallelScanColumnar(allocator, path, ',', &predicates, 8);
    defer colResult.deinit();

    try std.testing.expectEqual(rowResult.rows.len, colResult.n_rows);
    try std.testing.expectEqual(@as(usize, 3), colResult.n_cols);

    // Order isn't guaranteed to match between the two (both concatenate
    // worker ranges, but range boundaries can differ between the two
    // independent range-split calls) — verify via id-column SET
    // equality, same reasoning as the C ABI's own single-vs-parallel test.
    var row_ids = std.AutoHashMap(u64, void).init(allocator);
    defer row_ids.deinit();
    for (rowResult.rows) |r| {
        const id = try std.fmt.parseInt(u64, r.get(0).?, 10);
        try row_ids.put(id, {});
    }
    var j: usize = 0;
    while (j < colResult.n_rows) : (j += 1) {
        const id = try std.fmt.parseInt(u64, columnarCellValue(colResult, 0, j), 10);
        try std.testing.expect(row_ids.contains(id));
        try std.testing.expectEqualStrings("Austin", columnarCellValue(colResult, 1, j));
        const amount = try std.fmt.parseInt(u64, columnarCellValue(colResult, 2, j), 10);
        try std.testing.expectEqual(id * 3, amount);
    }
}

/// Wraps a child allocator and counts alloc() calls — used below as a
/// regression guard against parallelScanColumnar() silently reverting to
/// an OwnedRow-style per-field allocator.dupe(): that pattern costs one
/// alloc() call per (row, column) pair, whereas ColumnBuf's amortized
/// ArrayList growth costs one alloc() call per doubling, independent of
/// row count. A future change that reintroduces the double-copy would
/// blow this bound even though every existing correctness test (which
/// only checks VALUES, not allocation shape) would still pass.
const CountingAllocator = struct {
    child: Allocator,
    count: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "parallelScanColumnar: allocation count stays far below rows*cols (double-copy regression guard)" {
    const backing = std.testing.allocator;
    const path = "test_parallel_columnar_alloc_count.csv";

    var data: std.ArrayList(u8) = .{};
    defer data.deinit(backing);
    try data.appendSlice(backing, "id,city,amount\n");
    var i: usize = 0;
    const n_rows: usize = 20_000;
    while (i < n_rows) : (i += 1) {
        try data.writer(backing).print("{d},Austin,{d}\n", .{ i, i * 3 });
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data.items });
    defer std.fs.cwd().deleteFile(path) catch {};

    var counting = CountingAllocator{ .child = backing };
    const predicates = [_]query_mod.Predicate{query_mod.Predicate.init(1, .eq, "Austin")};

    var colResult = try parallelScanColumnar(counting.allocator(), path, ',', &predicates, 4);
    defer colResult.deinit();

    try std.testing.expectEqual(n_rows, colResult.n_rows);

    const n_cols: usize = 3;
    const owned_row_floor = n_rows * n_cols; // what a per-field allocator.dupe() approach would cost, at minimum
    try std.testing.expect(counting.count < owned_row_floor / 10);
}

test "parallelScanColumnar: NDJSON matches expected count and field consistency" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_columnar_ndjson.ndjson";

    var data: std.ArrayList(u8) = .{};
    defer data.deinit(allocator);
    var i: usize = 0;
    while (i < 30_000) : (i += 1) {
        const city = if (i % 4 == 0) "Austin" else "Denver";
        try data.writer(allocator).print("{{\"id\":{d},\"city\":\"{s}\",\"amount\":{d}}}\n", .{ i, city, i * 5 });
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data.items });
    defer std.fs.cwd().deleteFile(path) catch {};

    const scan = @import("root.zig");
    var q = try scan.Query.open(allocator, path, .{ .where = &.{scan.Predicate.init(1, .eq, "Austin")} });
    defer q.deinit();
    const expected_count = try q.count();

    const predicates = [_]query_mod.Predicate{query_mod.Predicate.init(1, .eq, "Austin")};
    var colResult = try parallelScanColumnar(allocator, path, ',', &predicates, 8);
    defer colResult.deinit();

    try std.testing.expectEqual(expected_count, colResult.n_rows);
    try std.testing.expectEqual(@as(usize, 7_500), colResult.n_rows);
    var j: usize = 0;
    while (j < colResult.n_rows) : (j += 1) {
        try std.testing.expectEqualStrings("Austin", columnarCellValue(colResult, 1, j));
        const id = try std.fmt.parseInt(u64, columnarCellValue(colResult, 0, j), 10);
        const amount = try std.fmt.parseInt(u64, columnarCellValue(colResult, 2, j), 10);
        try std.testing.expectEqual(id * 5, amount);
    }
}

test "parallelScanColumnar: JSON array matches expected count" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_columnar_json_array.json";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "[{\"id\":1,\"city\":\"Austin\"},{\"id\":2,\"city\":\"Denver\"},{\"id\":3,\"city\":\"Austin\"}]" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const predicates = [_]query_mod.Predicate{query_mod.Predicate.init(1, .eq, "Austin")};
    var colResult = try parallelScanColumnar(allocator, path, ',', &predicates, 4);
    defer colResult.deinit();

    try std.testing.expectEqual(@as(usize, 2), colResult.n_rows);
    try std.testing.expectEqualStrings("1", columnarCellValue(colResult, 0, 0));
    try std.testing.expectEqualStrings("3", columnarCellValue(colResult, 0, 1));
}

test "parallelScanColumnar: no predicates still scans every row" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_columnar_all.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id\n1\n2\n3\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var colResult = try parallelScanColumnar(allocator, path, ',', &.{}, 4);
    defer colResult.deinit();
    try std.testing.expectEqual(@as(usize, 3), colResult.n_rows);
}

test "parallelScanColumnar: empty file returns EmptyFile" {
    const allocator = std.testing.allocator;
    const path = "test_parallel_columnar_empty.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "" });
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.testing.expectError(ParallelError.EmptyFile, parallelScanColumnar(allocator, path, ',', &.{}, 4));
}
