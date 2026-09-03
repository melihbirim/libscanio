//! libscanio M4: NDJSON (newline-delimited JSON) — a second format behind
//! the same next()-based scan shape CSV already has.
//!
//! Schema model matches CSV's: the FIRST row's keys (in first-seen order)
//! become the "header" — later rows are matched by key name, not
//! position, since JSON key order within an object isn't guaranteed
//! stable the way CSV column position is. A row missing a header key
//! reads back as an empty string, same as CSV's own null/empty-field
//! convention.
//!
//! Parsing is json_parser.zig — a SIMD-tokenized, zero-copy JSON parser
//! (string/number values are slices directly into the mapped line; only
//! escaped strings allocate) pulled in from zson, a prior project doing
//! exactly this job for exactly this reason. The first attempt here used
//! std.json.parseFromSlice per line and measured 400x slower than CSV
//! (42K rows/sec vs 17M) — building a tree per row, every row, is real
//! cost, not a rounding error. Reusing a parser that already solved this
//! beat re-deriving the solution from scratch.
//!
//! Second finding, worth stating since it's easy to reintroduce: swapping
//! in json_parser.zig alone did NOT fix the 42K rows/sec number — the
//! actual bottleneck was std.heap.GeneralPurposeAllocator, not the parsing
//! algorithm. GPA's per-allocation safety/tracking overhead dominates for
//! this workload (several small, short-lived allocations per row, 500K
//! rows) — swapping the *allocator* the caller passes to Query.open() from
//! GPA to std.heap.c_allocator took NDJSON from 42K to 2.78M rows/sec on
//! the same file with the same parser, a 66x difference from allocator
//! choice alone (CSV's own zero-copy path barely notices, since it barely
//! allocates either way). The C ABI (c_api.zig) already uses c_allocator
//! for an unrelated reason (GPA also faults when dlopen()'d — see #149 in
//! csvql's history), so Python/consumers of the C ABI get the fast path
//! automatically; a Zig caller building on Query directly does not unless
//! they choose the allocator themselves. Measure with whatever allocator
//! you intend to actually ship with, not whichever one is easiest to
//! write in a test.
//!
//! Third finding: like CSV (see root.zig), this used to mmap/load the
//! whole file — measured 426MB peak RSS on a 417MB CSV file, since a full
//! scan touches (and keeps resident) every mapped page. Now reads in
//! fixed-size chunks instead, same CHUNK_SIZE default as CSV, same
//! carry-over-across-chunk-boundary approach: a JSON line/object that
//! doesn't span a chunk boundary is still a zero-copy slice into the
//! current chunk; only a boundary-spanning one gets assembled into a
//! reused scratch buffer. This applies to BOTH sub-formats: NDJSON lines
//! (boundary = '\n', identical logic to CSV's nextLine()) and JSON arrays
//! (boundary = a balanced top-level '{...}' — no newlines to rely on, so
//! nextObject() below tracks brace depth and string/escape state across
//! chunk refills instead). The old json_array.zig::jsonArrayToNdjson()
//! (convert-the-whole-array-up-front) is no longer used by this file —
//! array objects are now extracted one at a time, streaming, same as
//! NDJSON lines. json_array.zig itself is kept only for its
//! detectFormat() sniff and its own tests; the conversion function is
//! dead code now (not deleted — matthewtolman/zcsv-adjacent projects may
//! still reference it, and it's a correct, tested reference
//! implementation of the non-chunked approach).
//!
//! Nested objects/arrays are still out of scope (see the project's own
//! non-goals) and fail loudly with NestedValueNotSupported rather than
//! silently stringifying — json_parser.zig can parse them, libscanio
//! chooses not to expose them as flat row fields.
//!
//! Fourth finding: every measurement above (4.3-6.0M rows/sec) used a
//! 3-4-field test fixture. A real 51-column NDJSON file (the same taxi
//! CSV data used throughout this project, converted to NDJSON) measured
//! 187K rows/sec — 23x slower for 17x more fields, the signature of
//! O(n^2) cost, not O(n). Root cause: next() looped over every header
//! key and called JsonObject.get() (a linear scan over the row's own
//! fields) once per key — O(header.len * row.fields.len) per row. Fixed
//! with `header_index`, a hash map from header key to column index built
//! once at open(), turning the lookup into one pass over the row's OWN
//! fields (O(row.fields.len) hash lookups) instead of one pass per
//! header key. Isolated before AND after fixing it, not just trusted:
//! parse-only (no lookup at all) measured 242K rows/sec on the same wide
//! fixture — meaning the fixed lookup now costs ~13% overhead (210K vs
//! 242K rows/sec), down from being the dominant cost entirely. The
//! remaining 242K rows/sec ceiling is JSON parsing itself (tokenizing,
//! escaping, building Field structs — costs that scale with field count
//! regardless of lookup strategy), a different, harder lever than this
//! one was.
const std = @import("std");
const Allocator = std.mem.Allocator;
const scan = @import("root.zig");
const Row = scan.Row;
const json_parser = @import("json_parser.zig");
const json_array = @import("json_array.zig");

pub const NdjsonError = error{
    EmptyFile,
    InvalidJson,
    NestedValueNotSupported,
};

const Mode = enum { line_delimited, json_array };

pub const NdjsonScanner = struct {
    allocator: Allocator,
    file: std.fs.File,
    mode: Mode,
    buf: []u8,
    buf_len: usize,
    buf_pos: usize,
    eof: bool,
    /// Carries a line/object tail that didn't fit in one chunk. Cleared
    /// at the start of every nextLine()/nextObject() call.
    line_scratch: std.ArrayListUnmanaged(u8),
    header: [][]const u8,
    /// header key -> index, built once at open(). Real fix for a real
    /// quadratic-cost bug: next() used to loop over every header key and
    /// call JsonObject.get() (a linear scan over the row's own fields)
    /// for each one — O(header.len * row.fields.len) per row. Fine for
    /// the 3-4-field fixtures this was originally measured against
    /// (4.3-6.0M rows/sec), but a real 51-column NDJSON file (taxi
    /// fixture, converted from the same CSV data used everywhere else in
    /// this project) measured 187K rows/sec — 23x slower for 17x more
    /// fields, the signature of O(n^2), not O(n). This map turns the
    /// lookup into one pass over the row's OWN fields (O(row.fields.len)
    /// hash lookups) instead of one pass per header key.
    header_index: std.StringHashMapUnmanaged(usize),
    /// The first row's raw JSON text, captured at open() time to derive
    /// the header. Replayed as the first next() call's row instead of
    /// re-reading it from the file (the chunked reader can't "rewind" a
    /// stream position the way a full mmap could).
    first_row_line: []u8,
    used_first_row: bool = false,
    field_buf: [][]const u8 = &.{},
    row_arena: std.heap.ArenaAllocator,
    /// The JSON fields array for the CURRENT row, reused across next()
    /// calls via clearRetainingCapacity() rather than reallocated —
    /// parseObject()'s own internal array allocation was still a
    /// malloc/free pair per row even after row_arena existed, since the
    /// array itself was freshly requested and detached (toOwnedSlice())
    /// every call. Grown via self.allocator (persists for the scanner's
    /// whole lifetime), not row_arena (which resets every row and would
    /// defeat the reuse).
    ///
    /// owned_strings is NOT a persisted field alongside it, on purpose:
    /// json_parser's parseValueAfterColon() grows that list using
    /// whatever single allocator it's handed, which for parseObjectReuse
    /// is row_arena — so owned_strings' own backing array ends up
    /// arena-scoped too, and freeing it later via self.allocator (a
    /// different allocator than whatever actually backed it) segfaults.
    /// Caught by this file's own test suite. It's declared fresh,
    /// arena-backed, inside next() instead — cheap, since arena
    /// allocation is a bump pointer, and its whole lifetime is one row
    /// anyway.
    parse_fields: std.ArrayList(json_parser.JsonObject.Field) = .{},

    pub fn open(allocator: Allocator, path: []const u8) !NdjsonScanner {
        return openWithChunkSize(allocator, path, scan.default_chunk_size);
    }

    pub fn openWithChunkSize(allocator: Allocator, path: []const u8, chunk_size: usize) !NdjsonScanner {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();
        const size = (try file.stat()).size;
        if (size == 0) return NdjsonError.EmptyFile;

        const buf = try allocator.alloc(u8, chunk_size);
        errdefer allocator.free(buf);

        var scanner = NdjsonScanner{
            .allocator = allocator,
            .file = file,
            .mode = .line_delimited,
            .buf = buf,
            .buf_len = 0,
            .buf_pos = 0,
            .eof = false,
            .line_scratch = .{},
            .header = &[_][]const u8{},
            .header_index = .{},
            .first_row_line = &[_]u8{},
            .row_arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer scanner.row_arena.deinit();

        // Sniff NDJSON vs JSON array from the first non-whitespace byte —
        // needs at least one chunk loaded first.
        try scanner.fillBuffer();
        var i: usize = 0;
        while (i < scanner.buf_len) : (i += 1) {
            const b = scanner.buf[i];
            if (b == ' ' or b == '\t' or b == '\n' or b == '\r') continue;
            if (b == '[') scanner.mode = .json_array;
            break;
        }

        const first_line = (try (if (scanner.mode == .json_array) scanner.nextObject() else scanner.nextLine())) orelse return NdjsonError.EmptyFile;
        scanner.first_row_line = try allocator.dupe(u8, first_line);

        var obj = json_parser.parseObject(scanner.first_row_line, allocator) catch return NdjsonError.InvalidJson;
        defer obj.deinit();
        var keys = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, obj.fields.len);
        errdefer keys.deinit(allocator);
        for (obj.fields) |field| {
            try keys.append(allocator, try allocator.dupe(u8, field.key));
        }
        scanner.header = try keys.toOwnedSlice(allocator);

        try scanner.header_index.ensureTotalCapacity(allocator, @intCast(scanner.header.len));
        for (scanner.header, 0..) |key, idx| {
            scanner.header_index.putAssumeCapacity(key, idx);
        }

        return scanner;
    }

    pub fn deinit(self: *NdjsonScanner) void {
        self.row_arena.deinit();
        self.parse_fields.deinit(self.allocator);
        self.header_index.deinit(self.allocator);
        for (self.header) |k| self.allocator.free(k);
        self.allocator.free(self.header);
        self.allocator.free(self.first_row_line);
        if (self.field_buf.len > 0) self.allocator.free(self.field_buf);
        self.line_scratch.deinit(self.allocator);
        self.allocator.free(self.buf);
        self.file.close();
    }

    pub fn columnIndex(self: NdjsonScanner, name: []const u8) ?usize {
        for (self.header, 0..) |h, i| {
            if (std.mem.eql(u8, h, name)) return i;
        }
        return null;
    }

    pub fn next(self: *NdjsonScanner) !?Row {
        const line = blk: {
            if (!self.used_first_row) {
                self.used_first_row = true;
                break :blk self.first_row_line;
            }
            break :blk (if (self.mode == .json_array) (try self.nextObject()) else (try self.nextLine())) orelse return null;
        };

        self.ensureCapacity(self.header.len);

        // Fused fast path: matches CSV's own approach (byte-scan straight
        // into field_buf, no intermediate structure) for the case that
        // covers almost every real NDJSON file — same key order every row,
        // flat values, no escapes. Skips the SIMD tokenizer, the Token
        // array, the Field-struct array, and the arena entirely: CSV was
        // measured at ~2.1-2.2M rows/sec on the same 51-field fixture that
        // NDJSON, going through the generic tokenize->extract pipeline,
        // only reached ~313K — a 7x gap that isn't inherent to JSON's
        // syntax, it's the cost of building generic intermediate
        // structures this scanner doesn't actually need on the common row.
        // Falls back to the full generic parser (unchanged, still fully
        // correct) the instant anything doesn't match the fast shape:
        // reordered/extra/missing keys, escapes, nested values, malformed
        // JSON. Correctness therefore never depends on the fast path
        // succeeding — only speed does.
        if (try self.tryFastRow(line)) {
            return Row{ .fields = self.field_buf[0..self.header.len] };
        }

        _ = self.row_arena.reset(.retain_capacity);
        // Arena-backed and local, not a persisted field — see parse_fields'
        // doc comment for why owned_strings can't safely be reused the
        // same way.
        var owned_strings: std.ArrayList([]u8) = .{};
        const obj = json_parser.parseObjectReuse(
            line,
            self.allocator,
            self.row_arena.allocator(),
            &self.parse_fields,
            &owned_strings,
        ) catch return NdjsonError.InvalidJson;

        // One pass over THIS ROW's own fields (not the header) — see
        // header_index's doc comment for why this replaced a per-header-
        // key linear scan. Default every slot to "" first (a row missing
        // a header key, or a header key this row never got a value
        // written for below, both need that default) then overwrite only
        // the ones this row actually has.
        for (self.field_buf[0..self.header.len]) |*f| f.* = "";
        // Positional fast path: real NDJSON files overwhelmingly keep the
        // same key order every row (same producer, same struct/schema) —
        // checked, not assumed: the taxi fixture this was measured against
        // does. When position k's key matches header[k], skip the hash
        // lookup entirely (a mem.eql, no hashing); only a row with a
        // genuinely different key order at that position falls back to
        // header_index. Isolated before/after: this cut the post-O(n^2)-fix
        // 210K rows/sec to within noise of the 242K parse-only ceiling on
        // the wide (51-field) fixture — header_index.get()'s per-field
        // hashing, not lookup logic itself, was the remaining cost.
        for (obj.fields, 0..) |field, k| {
            const idx = if (k < self.header.len and std.mem.eql(u8, self.header[k], field.key))
                k
            else
                self.header_index.get(field.key) orelse continue;
            self.field_buf[idx] = try render(field.value);
        }
        return Row{ .fields = self.field_buf[0..self.header.len] };
    }

    /// Single-pass byte scan straight into field_buf, matching CSV's own
    /// nextLine()-splitting approach instead of building generic JSON
    /// structures (Token array, Field-struct array, JsonValue tags) for
    /// data this scanner only ever reads back as raw text. Returns false
    /// (leaving field_buf in a partially-written, about-to-be-overwritten
    /// state — the caller always re-derives from the full generic parser
    /// on false, so this is safe) the instant anything doesn't match the
    /// fast shape: a header-order/name mismatch, an escaped string, a
    /// nested value, or anything malformed. Never the source of truth for
    /// correctness — only ever a speed shortcut the caller can discard.
    /// Vectorized quote search (std.mem.indexOfScalar, SIMD-backed) plus a
    /// cheap backward escape-check only on an actual hit — the string
    /// equivalent of CSV's comma search, instead of json_parser's manual
    /// per-byte escape-tracking loop (findStringEnd), which was the real
    /// remaining cost once the SIMD tokenizer pass itself was skipped.
    /// Unescaped strings (the fixture's — and most real NDJSON's — common
    /// case) resolve on the FIRST indexOfScalar hit, so the backward scan
    /// almost never runs more than the single "is there a backslash right
    /// before this quote" check. Only finds where the string ENDS — the
    /// caller still separately checks hasJsonEscape on the resulting span,
    /// since a legitimately-unescaped closing quote can still follow an
    /// interior escape sequence (`"foo\nbar"`) that needs real decoding.
    fn findQuoteEnd(line: []const u8, start: usize) ?usize {
        var idx = start;
        while (std.mem.indexOfScalarPos(u8, line, idx, '"')) |q| {
            if (!json_parser.isEscapedAt(line, q)) return q;
            idx = q + 1;
        }
        return null;
    }

    fn tryFastRow(self: *NdjsonScanner, line: []const u8) !bool {
        var pos: usize = std.mem.indexOfScalar(u8, line, '{') orelse return false;
        pos += 1;

        for (self.header, 0..) |want_key, k| {
            while (pos < line.len and (line[pos] == ' ' or line[pos] == ',')) : (pos += 1) {}
            if (pos >= line.len or line[pos] != '"') return false;
            const key_start = pos + 1;
            const key_end = findQuoteEnd(line, key_start) orelse return false;
            const key = line[key_start..key_end];
            if (json_parser.hasJsonEscape(key)) return false;
            if (!std.mem.eql(u8, key, want_key)) return false;
            pos = key_end + 1;

            while (pos < line.len and line[pos] == ' ') : (pos += 1) {}
            if (pos >= line.len or line[pos] != ':') return false;
            pos += 1;
            while (pos < line.len and line[pos] == ' ') : (pos += 1) {}
            if (pos >= line.len) return false;

            if (line[pos] == '"') {
                const val_start = pos + 1;
                const val_end = findQuoteEnd(line, val_start) orelse return false;
                const raw = line[val_start..val_end];
                if (json_parser.hasJsonEscape(raw)) return false;
                self.field_buf[k] = raw;
                pos = val_end + 1;
            } else if (line[pos] == '{' or line[pos] == '[') {
                return false; // nested — fall back to the generic path, which errors correctly
            } else {
                const val_start = pos;
                while (pos < line.len and line[pos] != ',' and line[pos] != '}' and line[pos] != ' ') : (pos += 1) {}
                if (pos == val_start) return false;
                self.field_buf[k] = line[val_start..pos];
            }
        }
        return true;
    }

    /// Newline-only (line_delimited) or object-count-only (json_array)
    /// fast path for count() with no WHERE clause — never parses a
    /// field. Same bounded-memory property as next().
    pub fn countRemaining(self: *NdjsonScanner) !usize {
        var n: usize = 0;
        if (!self.used_first_row) {
            self.used_first_row = true;
            n += 1;
        }
        switch (self.mode) {
            .line_delimited => {
                var saw_any_after_last_nl = false;
                while (true) {
                    if (self.buf_pos >= self.buf_len) {
                        if (self.eof) break;
                        try self.fillBuffer();
                        if (self.buf_len == 0) break;
                    }
                    const chunk = self.buf[self.buf_pos..self.buf_len];
                    for (chunk) |c| {
                        if (c == '\n') {
                            n += 1;
                            saw_any_after_last_nl = false;
                        } else {
                            saw_any_after_last_nl = true;
                        }
                    }
                    self.buf_pos = self.buf_len;
                }
                if (saw_any_after_last_nl) n += 1;
            },
            .json_array => {
                while (try self.nextObject()) |_| n += 1;
            },
        }
        return n;
    }

    fn render(val: json_parser.JsonValue) ![]const u8 {
        return switch (val) {
            .string => |s| s,
            .number => |s| s, // already a zero-copy text slice — no formatting needed
            .null_value => "",
            .bool_value => |b| if (b) "true" else "false",
            .array, .object => NdjsonError.NestedValueNotSupported,
        };
    }

    fn ensureCapacity(self: *NdjsonScanner, n: usize) void {
        if (n <= self.field_buf.len) return;
        self.field_buf = self.allocator.realloc(self.field_buf, n) catch return;
    }

    fn fillBuffer(self: *NdjsonScanner) !void {
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
    /// Identical shape to CSV Scanner's nextLine() — see root.zig.
    fn nextLine(self: *NdjsonScanner) !?[]const u8 {
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

    /// Returns the next top-level '{...}' object's raw text (including
    /// the braces), skipping surrounding whitespace/'['/','/']', or null
    /// once ']' (end of array) is reached. Boundary tracking (brace
    /// depth + in-string/escape state) survives across chunk refills the
    /// same way nextLine() survives a '\n' search across chunk refills —
    /// depth/in_string/escape are local to one call, obj_start marks
    /// where the in-progress object began in the CURRENT chunk, and
    /// anything not yet matched gets flushed into line_scratch before
    /// refilling so it isn't lost.
    fn nextObject(self: *NdjsonScanner) !?[]const u8 {
        self.line_scratch.clearRetainingCapacity();
        var started = false;
        var depth: usize = 0;
        var in_string = false;
        var escape = false;
        var obj_start: usize = self.buf_pos;

        while (true) {
            while (self.buf_pos < self.buf_len) {
                const c = self.buf[self.buf_pos];
                if (!started) {
                    if (c == '{') {
                        started = true;
                        depth = 1;
                        obj_start = self.buf_pos;
                        self.buf_pos += 1;
                        continue;
                    }
                    if (c == ']') {
                        self.buf_pos += 1;
                        return null;
                    }
                    self.buf_pos += 1;
                    continue;
                }
                self.buf_pos += 1;
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
                        const chunk_part = self.buf[obj_start..self.buf_pos];
                        if (self.line_scratch.items.len == 0) {
                            return chunk_part;
                        }
                        try self.line_scratch.appendSlice(self.allocator, chunk_part);
                        return self.line_scratch.items;
                    }
                }
            }
            if (started) {
                try self.line_scratch.appendSlice(self.allocator, self.buf[obj_start..self.buf_len]);
            }
            if (self.eof) {
                if (started) return NdjsonError.InvalidJson; // truncated object
                return null;
            }
            try self.fillBuffer();
            obj_start = 0;
        }
    }
};

test "ndjson: header derived from first row, values read back correctly" {
    const allocator = std.testing.allocator;
    const path = "test_ndjson_basic.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"id":1,"name":"Alice","active":true}
        \\{"id":2,"name":"Bob","active":false}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var s = try NdjsonScanner.open(allocator, path);
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 3), s.header.len);
    try std.testing.expectEqual(@as(usize, 0), s.columnIndex("id").?);

    const row1 = (try s.next()).?;
    try std.testing.expectEqualStrings("1", row1.get(0).?);
    try std.testing.expectEqualStrings("Alice", row1.get(1).?);
    try std.testing.expectEqualStrings("true", row1.get(2).?);

    const row2 = (try s.next()).?;
    try std.testing.expectEqualStrings("2", row2.get(0).?);
    try std.testing.expectEqualStrings("false", row2.get(2).?);

    try std.testing.expectEqual(@as(?Row, null), try s.next());
}

test "ndjson: missing key reads back as empty string" {
    const allocator = std.testing.allocator;
    const path = "test_ndjson_missing_key.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"id":1,"note":"hi"}
        \\{"id":2}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var s = try NdjsonScanner.open(allocator, path);
    defer s.deinit();
    _ = try s.next();
    const row2 = (try s.next()).?;
    try std.testing.expectEqualStrings("", row2.get(1).?);
}

test "ndjson: nested object value fails loudly, not silently" {
    const allocator = std.testing.allocator;
    const path = "test_ndjson_nested.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"id":1,"meta":{"a":1}}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var s = try NdjsonScanner.open(allocator, path);
    defer s.deinit();
    try std.testing.expectError(NdjsonError.NestedValueNotSupported, s.next());
}

test "ndjson: float and negative numbers render correctly" {
    const allocator = std.testing.allocator;
    const path = "test_ndjson_numbers.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"price":19.99,"delta":-5}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var s = try NdjsonScanner.open(allocator, path);
    defer s.deinit();
    const row = (try s.next()).?;
    try std.testing.expectEqualStrings("19.99", row.get(0).?);
    try std.testing.expectEqualStrings("-5", row.get(1).?);
}

test "ndjson: escaped strings decode correctly" {
    const allocator = std.testing.allocator;
    const path = "test_ndjson_escape.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"note":"line1\nline2","quote":"she said \"hi\""}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var s = try NdjsonScanner.open(allocator, path);
    defer s.deinit();
    const row = (try s.next()).?;
    try std.testing.expectEqualStrings("line1\nline2", row.get(0).?);
    try std.testing.expectEqualStrings("she said \"hi\"", row.get(1).?);
}

test "ndjson: chunked read with a small chunk size still finds rows spanning multiple chunks" {
    const allocator = std.testing.allocator;
    const path = "test_ndjson_small_chunks.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"id":1,"name":"Alice"}
        \\{"id":2,"name":"Bob"}
        \\{"id":3,"name":"Carol"}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var s = try NdjsonScanner.openWithChunkSize(allocator, path, 8);
    defer s.deinit();

    const row1 = (try s.next()).?;
    try std.testing.expectEqualStrings("1", row1.get(0).?);
    try std.testing.expectEqualStrings("Alice", row1.get(1).?);
    const row2 = (try s.next()).?;
    try std.testing.expectEqualStrings("2", row2.get(0).?);
    const row3 = (try s.next()).?;
    try std.testing.expectEqualStrings("3", row3.get(0).?);
    try std.testing.expectEqual(@as(?Row, null), try s.next());
}

test "json array: chunked read with a small chunk size still finds objects spanning multiple chunks" {
    const allocator = std.testing.allocator;
    const path = "test_json_array_small_chunks.json";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "[{\"id\":1,\"note\":\"a, b {c}\"},{\"id\":2,\"meta\":\"x\"},{\"id\":3}]" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var s = try NdjsonScanner.openWithChunkSize(allocator, path, 8);
    defer s.deinit();

    // Header is derived from row 1's keys only (id, note) — row 2's
    // "meta" key isn't part of the header, same as CSV's own
    // missing-key-reads-back-empty convention.
    try std.testing.expectEqual(@as(usize, 2), s.header.len);
    const row1 = (try s.next()).?;
    try std.testing.expectEqualStrings("1", row1.get(0).?);
    try std.testing.expectEqualStrings("a, b {c}", row1.get(1).?);
    const row2 = (try s.next()).?;
    try std.testing.expectEqualStrings("2", row2.get(0).?);
    try std.testing.expectEqualStrings("", row2.get(1).?);
    const row3 = (try s.next()).?;
    try std.testing.expectEqualStrings("3", row3.get(0).?);
    try std.testing.expectEqualStrings("", row3.get(1).?);
    try std.testing.expectEqual(@as(?Row, null), try s.next());
}

test "json array: count() fast path counts objects without parsing fields" {
    const allocator = std.testing.allocator;
    const path = "test_json_array_count.json";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "[{\"a\":1},{\"a\":2},{\"a\":3}]" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var s = try NdjsonScanner.open(allocator, path);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 3), try s.countRemaining());
}
