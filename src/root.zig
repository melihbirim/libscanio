//! libscanio M1: file source + CSV parser + next() + row streaming.
//!
//! Bounded-memory by construction, not just "no per-row allocation": the
//! file is read in fixed-size chunks (CHUNK_SIZE, currently 1MB), reused
//! across the whole scan, not memory-mapped. Peak RSS tracks the chunk
//! size, not the file size — a 10GB file costs the same ~1MB working set
//! as a 10MB one. This replaced an earlier mmap-based design: mmap gave
//! zero-copy rows for free, but touching every byte to scan it faults in
//! (and keeps resident) every page of the file, so peak RSS == file size
//! by construction — measured directly (`/usr/bin/time -l`) on a 417MB
//! fixture: 426MB peak either way you scan it. `cat`, by contrast, reads
//! and discards fixed 64KB-ish chunks and holds ~1.4MB regardless of file
//! size. Chunked reads get libscanio into that same bounded regime.
//!
//! Almost every Row's fields are still zero-copy slices into the current
//! chunk buffer — the fast path costs nothing extra. Only a line that
//! straddles a chunk boundary (rare, only near each chunk edge) gets
//! assembled into a small reused scratch buffer (line_scratch) instead;
//! same "valid until the next next() call" contract either way, so this
//! doesn't change the API.
const std = @import("std");
const Allocator = std.mem.Allocator;
const simd_count = @import("simd_count.zig");
const csv = @import("csv.zig");
/// Re-exported so the CLI (a separate module that depends on this one)
/// writes CSV with the same quoting rules this one reads it with,
/// instead of compiling a second copy of the splitter.
pub const csv_fields = csv;

/// Default read-buffer size, overridable per-Scanner via ScannerOptions
/// (and per-Query via QueryOptions.csv_chunk_size). Bigger = fewer read()
/// syscalls, higher peak RSS; smaller = more syscalls, lower peak RSS.
/// Measured on a 417MB/1M-row/51-col file, 10 runs each: time is flat
/// (0.56-0.58s) from 64KB through 4MB — syscall count isn't the
/// bottleneck anywhere in that range — while RSS scales roughly linearly
/// with chunk size (64KB: 2.0MB, 256KB: 2.2MB, 1MB: 3.0MB, 4MB: 6.1MB).
/// 16MB was a strict loss on both axes (0.60s, 18.7MB) — the buffer
/// itself gets big enough to cost first-touch time. 256KB is the default:
/// same time as 1MB, 26% less RSS, with enough margin above 64KB to avoid
/// its run-to-run variance.
const CHUNK_SIZE = 256 * 1024;
pub const default_chunk_size = CHUNK_SIZE;

pub const ScannerOptions = struct {
    delimiter: u8 = ',',
    chunk_size: usize = CHUNK_SIZE,
    /// If set, splitInto() stops once it has captured field index
    /// `stop_after_column` (inclusive) — fields past that index are
    /// never scanned for this row at all, not just discarded. Null
    /// (default) splits every field, same as before this existed. Set
    /// this to the highest column index a caller will actually read
    /// (the max of every WHERE predicate's column and every projected
    /// column) — anything past it is provably never read, so skipping
    /// it is always safe, never a behavior change from the caller's
    /// perspective. Rows with FEWER fields than this still return
    /// correctly (the line-end check still applies); this only lets a
    /// WIDE row's unneeded tail go unscanned.
    stop_after_column: ?usize = null,
};

const query_mod = @import("query.zig");
pub const Query = query_mod.Query;
pub const QueryOptions = query_mod.QueryOptions;
pub const Predicate = query_mod.Predicate;
pub const Op = query_mod.Op;
pub const parseNumeric = query_mod.parseNumeric;

const ndjson_mod = @import("ndjson.zig");
pub const NdjsonScanner = ndjson_mod.NdjsonScanner;
pub const NdjsonError = ndjson_mod.NdjsonError;

// Vendored from zson (github.com/melihbirim/zson, MIT, same author) —
// a SIMD-tokenized, zero-copy JSON line parser. Adopted after the
// first NDJSON attempt (std.json.parseFromSlice per line) measured
// 400x slower than CSV; see ndjson.zig's own doc comment.
const json_parser_mod = @import("json_parser.zig");
const json_simd_mod = @import("json_simd.zig");
const json_array_mod = @import("json_array.zig");

const aggregate_mod = @import("aggregate.zig");
pub const AggResult = aggregate_mod.AggResult;
pub const aggregate = aggregate_mod.aggregate;

const topk_mod = @import("topk.zig");
pub const TopK = topk_mod.TopK;
pub const OwnedRow = topk_mod.OwnedRow;
pub const Entry = topk_mod.Entry;
pub const topK = topk_mod.topK;

const parallel_mod = @import("parallel.zig");
pub const ParallelError = parallel_mod.ParallelError;
pub const parallelCountRows = parallel_mod.parallelCountRows;
pub const parallelCountRowsWhere = parallel_mod.parallelCountRowsWhere;
pub const parallelScan = parallel_mod.parallelScan;
pub const ScannedRows = parallel_mod.ScannedRows;
pub const parallelScanColumnar = parallel_mod.parallelScanColumnar;
pub const ColumnarScanResult = parallel_mod.ColumnarScanResult;
pub const ColumnBuf = parallel_mod.ColumnBuf;

const order_mod = @import("order.zig");
pub const OrderedRows = order_mod.OrderedRows;
pub const orderBy = order_mod.orderBy;

test {
    _ = query_mod;
    _ = ndjson_mod;
    _ = aggregate_mod;
    _ = topk_mod;
    _ = order_mod;
    _ = json_parser_mod;
    _ = json_simd_mod;
    _ = parallel_mod;
    _ = json_array_mod;
    _ = simd_count;
}

pub const Row = struct {
    fields: []const []const u8,

    pub fn get(self: Row, index: usize) ?[]const u8 {
        if (index >= self.fields.len) return null;
        return self.fields[index];
    }
};

pub const ScanError = error{
    EmptyFile,
};

pub const Scanner = struct {
    allocator: Allocator,
    file: std.fs.File,
    buf: []u8,
    buf_len: usize,
    buf_pos: usize,
    eof: bool,
    /// Carries the tail of a line that didn't fit in one chunk. Cleared
    /// at the start of every nextLine() call — see nextLine()'s comment
    /// for why that timing matters.
    line_scratch: std.ArrayListUnmanaged(u8),
    delimiter: u8,
    /// Owned copy — unlike per-row fields, the header must outlive chunk
    /// reuse for the scanner's whole lifetime (columnIndex, C ABI header
    /// listing, etc.), so it can't be a slice into the reused buf.
    header_line: []u8,
    header: [][]const u8,
    field_buf: [][]const u8,
    stop_after_column: ?usize,
    /// Unescaping buffer for quoted fields containing `""`. Reused across
    /// rows; see csv.FieldIterator for why one reservation per line keeps
    /// the field slices valid.
    quote_scratch: std.ArrayListUnmanaged(u8) = .{},

    pub fn open(allocator: Allocator, path: []const u8) !Scanner {
        return openWithOptions(allocator, path, .{});
    }

    pub fn openWithDelimiter(allocator: Allocator, path: []const u8, delimiter: u8) !Scanner {
        return openWithOptions(allocator, path, .{ .delimiter = delimiter });
    }

    pub fn openWithOptions(allocator: Allocator, path: []const u8, options: ScannerOptions) !Scanner {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();
        const size = (try file.stat()).size;
        if (size == 0) return ScanError.EmptyFile;

        const buf = try allocator.alloc(u8, options.chunk_size);
        errdefer allocator.free(buf);

        var scanner = Scanner{
            .allocator = allocator,
            .file = file,
            .buf = buf,
            .buf_len = 0,
            .buf_pos = 0,
            .eof = false,
            .line_scratch = .{},
            .delimiter = options.delimiter,
            .stop_after_column = options.stop_after_column,
            .header_line = &[_]u8{},
            .header = &[_][]const u8{},
            .field_buf = &[_][]const u8{},
        };

        // nextLine() can grow line_scratch (a header spanning a chunk
        // boundary), and neither it nor header_line below is reachable
        // for cleanup on an error return — deinit() only runs for a
        // scanner that was successfully returned.
        errdefer scanner.line_scratch.deinit(allocator);
        // splitOwned reserves capacity in quote_scratch before it can
        // fail on the next allocation, so the same rule applies to it.
        errdefer scanner.quote_scratch.deinit(allocator);

        const header_line = (try scanner.nextLine()) orelse return ScanError.EmptyFile;
        scanner.header_line = try allocator.dupe(u8, header_line);
        errdefer allocator.free(scanner.header_line);
        scanner.header = try scanner.splitOwned(scanner.header_line);
        return scanner;
    }

    pub fn deinit(self: *Scanner) void {
        for (self.header) |h| self.allocator.free(@constCast(h));
        self.allocator.free(self.header);
        self.allocator.free(self.header_line);
        self.quote_scratch.deinit(self.allocator);
        if (self.field_buf.len > 0) self.allocator.free(self.field_buf);
        self.line_scratch.deinit(self.allocator);
        self.allocator.free(self.buf);
        self.file.close();
    }

    pub fn columnIndex(self: Scanner, name: []const u8) ?usize {
        for (self.header, 0..) |h, i| {
            if (std.mem.eql(u8, h, name)) return i;
        }
        return null;
    }

    /// Returns the next row, or null at EOF. The returned Row's fields
    /// slice is only valid until the next call to next() — it's a reused
    /// scratch buffer, not a fresh allocation per row.
    pub fn next(self: *Scanner) !?Row {
        const line = (try self.nextLine()) orelse return null;
        const n = try self.splitInto(line);
        return Row{ .fields = self.field_buf[0..n] };
    }

    /// Newline-only fast path for count() with no WHERE clause: reads
    /// through the rest of the file in chunks, counting '\n' without
    /// splitting a single field. Same bounded-memory property as next().
    /// Counting itself is vectorized (simd_count.countByte) — the scalar
    /// per-byte loop this replaced was measured against xan (Rust,
    /// SIMD-backed byte search) on a real 10.46GB/130M-row file: xan
    /// counted rows in 6.00s, this loop took 13.41s for the identical
    /// operation — over 2x slower for pure byte comparison, nothing
    /// CSV-specific about the cost. See simd_count.zig's doc comment.
    pub fn countRemaining(self: *Scanner) !usize {
        var n: usize = 0;
        var last_byte: ?u8 = null;
        while (true) {
            if (self.buf_pos >= self.buf_len) {
                if (self.eof) break;
                try self.fillBuffer();
                if (self.buf_len == 0) break;
            }
            const chunk = self.buf[self.buf_pos..self.buf_len];
            n += simd_count.countByte(chunk, '\n');
            last_byte = chunk[chunk.len - 1];
            self.buf_pos = self.buf_len;
        }
        // A final row with no trailing newline still counts.
        if (last_byte) |b| {
            if (b != '\n') n += 1;
        }
        return n;
    }

    fn fillBuffer(self: *Scanner) !void {
        const n = try self.file.read(self.buf);
        self.buf_len = n;
        self.buf_pos = 0;
        if (n == 0) self.eof = true;
    }

    fn trimCR(line: []const u8) []const u8 {
        if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
        return line;
    }

    /// Returns the next line (without its terminator), or null at EOF.
    /// The fast path (line doesn't cross a chunk boundary) is a zero-copy
    /// slice into buf. The slow path (line spans a chunk boundary)
    /// assembles it into line_scratch instead. Either way, the returned
    /// slice is only valid until the next call — line_scratch is cleared
    /// at the *start* of this function, not before returning, so a line
    /// built up across several fillBuffer() calls within one invocation
    /// stays intact for the caller.
    fn nextLine(self: *Scanner) !?[]const u8 {
        self.line_scratch.clearRetainingCapacity();
        while (true) {
            if (self.buf_pos < self.buf_len) {
                if (std.mem.indexOfScalar(u8, self.buf[self.buf_pos..self.buf_len], '\n')) |rel| {
                    const abs_end = self.buf_pos + rel;
                    const chunk_part = self.buf[self.buf_pos..abs_end];
                    self.buf_pos = abs_end + 1;
                    if (self.line_scratch.items.len == 0) {
                        return trimCR(chunk_part);
                    }
                    try self.line_scratch.appendSlice(self.allocator, chunk_part);
                    return trimCR(self.line_scratch.items);
                }
                try self.line_scratch.appendSlice(self.allocator, self.buf[self.buf_pos..self.buf_len]);
                self.buf_pos = self.buf_len;
            }
            if (self.eof) {
                if (self.line_scratch.items.len > 0) return trimCR(self.line_scratch.items);
                return null;
            }
            try self.fillBuffer();
        }
    }

    /// Split a line into the reusable field_buf, growing it if this row
    /// has more fields than any row seen so far. Returns the field count.
    ///
    /// Measured: a std.mem.indexOfScalarPos-per-field version (SIMD, same
    /// approach nextLine() uses for '\n') was tried and made this *slower*
    /// (0.42s -> 0.58s on a 1M-row/51-col file) — fields here average ~8
    /// bytes, and indexOfScalarPos's per-call setup cost dominates at that
    /// length. The plain scalar scan wins for short, narrow fields; only
    /// worth revisiting for schemas with long text fields.
    fn splitInto(self: *Scanner, line: []const u8) !usize {
        var count: usize = 0;
        var it = try csv.FieldIterator.init(self.allocator, line, self.delimiter, &self.quote_scratch);
        while (try it.next()) |field| {
            try self.ensureFieldCapacity(count + 1);
            self.field_buf[count] = field;
            count += 1;
            // Everything past stop_after_column is provably never read by
            // this Query (see ScannerOptions' doc comment) — stop scanning
            // the rest of the line's bytes entirely, not just skip storing
            // them.
            if (self.stop_after_column) |stop| {
                if (count == stop + 1) return count;
            }
        }
        return count;
    }

    /// Grows field_buf to hold `needed` field slices.
    ///
    /// Returns the allocation error rather than swallowing it: it used to
    /// `catch return`, leaving the OLD, smaller buffer in place — and
    /// splitInto's very next statement is `self.field_buf[count] = ...`,
    /// an out-of-bounds heap write on exactly the path that was meant to
    /// be handling the failure. (Same bug, and same fix, as
    /// growFieldBuffers in c_api.zig.)
    fn ensureFieldCapacity(self: *Scanner, needed: usize) !void {
        if (needed <= self.field_buf.len) return;
        self.field_buf = try self.allocator.realloc(self.field_buf, needed);
    }

    /// One-shot split that owns its own slice (used only for the header).
    /// Header fields, each an OWNED copy.
    ///
    /// They used to be views into `header_line`, which was fine when a
    /// field was always a verbatim slice of it. A quoted header field
    /// containing `""` is unescaped into the shared scratch buffer
    /// instead, and that buffer is reused by the very next row — so the
    /// header has to own its own bytes now. Freed per element in
    /// deinit().
    fn splitOwned(self: *Scanner, line: []const u8) ![][]const u8 {
        var list = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (list.items) |f| self.allocator.free(@constCast(f));
            list.deinit(self.allocator);
        }
        var it = try csv.FieldIterator.init(self.allocator, line, self.delimiter, &self.quote_scratch);
        while (try it.next()) |field| {
            // Two allocations, so the copy needs its own errdefer: if the
            // append is the one that fails, the copy is not in the list
            // for the block above to free.
            const owned = try self.allocator.dupe(u8, field);
            errdefer self.allocator.free(owned);
            try list.append(self.allocator, owned);
        }
        return list.toOwnedSlice(self.allocator);
    }
};

test "scans a simple CSV, header parsed, rows streamed" {
    const allocator = std.testing.allocator;
    const path = "test_simple.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,name\n1,Alice\n2,Bob\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var scanner = try Scanner.open(allocator, path);
    defer scanner.deinit();

    try std.testing.expectEqual(@as(usize, 2), scanner.header.len);
    try std.testing.expectEqualStrings("id", scanner.header[0]);
    try std.testing.expectEqualStrings("name", scanner.header[1]);
    try std.testing.expectEqual(@as(usize, 0), scanner.columnIndex("id").?);
    try std.testing.expectEqual(@as(usize, 1), scanner.columnIndex("name").?);
    try std.testing.expectEqual(@as(?usize, null), scanner.columnIndex("nope"));

    const row1 = (try scanner.next()).?;
    try std.testing.expectEqualStrings("1", row1.get(0).?);
    try std.testing.expectEqualStrings("Alice", row1.get(1).?);

    const row2 = (try scanner.next()).?;
    try std.testing.expectEqualStrings("2", row2.get(0).?);
    try std.testing.expectEqualStrings("Bob", row2.get(1).?);

    try std.testing.expectEqual(@as(?Row, null), try scanner.next());
}

test "handles CRLF line endings" {
    const allocator = std.testing.allocator;
    const path = "test_crlf.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "a,b\r\n1,2\r\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var scanner = try Scanner.open(allocator, path);
    defer scanner.deinit();

    const row = (try scanner.next()).?;
    try std.testing.expectEqualStrings("1", row.get(0).?);
    try std.testing.expectEqualStrings("2", row.get(1).?);
}

test "file with no trailing newline still yields the last row" {
    const allocator = std.testing.allocator;
    const path = "test_no_trailing_nl.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "a,b\n1,2" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var scanner = try Scanner.open(allocator, path);
    defer scanner.deinit();

    const row = (try scanner.next()).?;
    try std.testing.expectEqualStrings("1", row.get(0).?);
    try std.testing.expectEqualStrings("2", row.get(1).?);
    try std.testing.expectEqual(@as(?Row, null), try scanner.next());
}

test "empty file returns EmptyFile error" {
    const allocator = std.testing.allocator;
    const path = "test_empty.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "" });
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.testing.expectError(ScanError.EmptyFile, Scanner.open(allocator, path));
}

test "custom delimiter (tab)" {
    const allocator = std.testing.allocator;
    const path = "test_tsv.tsv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "a\tb\n1\t2\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var scanner = try Scanner.openWithDelimiter(allocator, path, '\t');
    defer scanner.deinit();

    const row = (try scanner.next()).?;
    try std.testing.expectEqualStrings("1", row.get(0).?);
    try std.testing.expectEqualStrings("2", row.get(1).?);
}

test "row field count varies across rows (ragged CSV) without leaking stale fields" {
    const allocator = std.testing.allocator;
    const path = "test_ragged.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "a,b,c\n1,2,3\n4,5\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var scanner = try Scanner.open(allocator, path);
    defer scanner.deinit();

    const row1 = (try scanner.next()).?;
    try std.testing.expectEqual(@as(usize, 3), row1.fields.len);

    const row2 = (try scanner.next()).?;
    try std.testing.expectEqual(@as(usize, 2), row2.fields.len);
}

test "stop_after_column truncates the row, doesn't scan or return trailing fields" {
    const allocator = std.testing.allocator;
    const path = "test_stop_after_column.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "a,b,c,d,e\n1,2,3,4,5\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var scanner = try Scanner.openWithOptions(allocator, path, .{ .stop_after_column = 1 });
    defer scanner.deinit();

    // Header is unaffected — stop_after_column only bounds per-row next().
    try std.testing.expectEqual(@as(usize, 5), scanner.header.len);

    const row = (try scanner.next()).?;
    try std.testing.expectEqual(@as(usize, 2), row.fields.len);
    try std.testing.expectEqualStrings("1", row.get(0).?);
    try std.testing.expectEqualStrings("2", row.get(1).?);
    try std.testing.expectEqual(@as(?[]const u8, null), row.get(2));
}

test "stop_after_column past a short row still returns correctly (ragged CSV)" {
    const allocator = std.testing.allocator;
    const path = "test_stop_after_column_ragged.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "a,b,c,d,e\n1,2\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var scanner = try Scanner.openWithOptions(allocator, path, .{ .stop_after_column = 3 });
    defer scanner.deinit();

    const row = (try scanner.next()).?;
    try std.testing.expectEqual(@as(usize, 2), row.fields.len);
    try std.testing.expectEqualStrings("1", row.get(0).?);
    try std.testing.expectEqualStrings("2", row.get(1).?);
}

test "Scanner: an OOM growing field_buf surfaces as an error, not an out-of-bounds write" {
    // field_buf grows one field at a time from empty, so every field of
    // every row is a potential failure point. Before this, a failed
    // realloc left the smaller buffer in place and splitInto wrote past
    // its end; now the error reaches the caller. Walking every failure
    // index also proves none of them leak.
    const backing = std.testing.allocator;
    const path = "test_scanner_fieldbuf_oom.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "a,b,c\n1,2,3\n4,5,6\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var fail_index: usize = 0;
    while (fail_index < 40) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        var sc = Scanner.open(failing.allocator(), path) catch |e| {
            try std.testing.expectEqual(error.OutOfMemory, e);
            continue;
        };
        defer sc.deinit();

        var rows: usize = 0;
        while (true) {
            const row = sc.next() catch |e| {
                try std.testing.expectEqual(error.OutOfMemory, e);
                break;
            } orelse break;
            // Whenever a row does come back, it is fully formed.
            try std.testing.expectEqual(@as(usize, 3), row.fields.len);
            rows += 1;
        }
        try std.testing.expect(rows <= 2);
    }
}
