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

const CsvFilterCtx = struct {
    allocator: Allocator,
    delimiter: u8,
    predicates: []const query_mod.Predicate,
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
    result: usize = 0,
    err: ?anyerror = null,
};

fn csvFilterWorkerRun(w: *CsvFilterWorker) void {
    var ctx = CsvFilterCtx{ .allocator = w.allocator, .delimiter = w.delimiter, .predicates = w.predicates };
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
/// as Query.open()/the Python/Node bindings already do). CSV and NDJSON
/// run the real parallel path (NDJSON via a shared, once-built
/// header_index — see buildNdjsonHeader()). JSON arrays delegate to the
/// existing single-threaded Query/NdjsonScanner path instead — not a
/// missing feature, a deliberate non-duplication: a JSON array's Nth
/// object boundary can only be found by walking brace depth from the
/// start of the file (see countJsonArrayObjects()'s doc comment above),
/// so a correct parallel split needs a sequential pre-pass that already
/// costs as much as doing the filtering directly — reimplementing JSON-
/// object parsing a third time in this file for zero speed benefit
/// isn't worth the maintenance cost of a third copy of that logic.
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
        // Query.open() below opens its own handle — this function's
        // `file` (and its `defer file.close()` above) still owns and
        // closes the one used for sniffing; two independent read-only
        // opens of the same path is safe on every platform.
        var q = try query_mod.Query.open(allocator, path, .{ .where = predicates, .format = .ndjson });
        defer q.deinit();
        return q.count();
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
        const workers = try allocator.alloc(CsvFilterWorker, num_threads);
        defer allocator.free(workers);
        const threads = try allocator.alloc(std.Thread, num_threads);
        defer allocator.free(threads);
        for (ranges, 0..) |r, i| workers[i] = .{ .allocator = allocator, .file = file, .range = r, .delimiter = delimiter, .predicates = predicates };
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
