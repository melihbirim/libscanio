//! One CSV field splitter, shared by every path that reads a CSV record.
//!
//! There were five copies of `while (i <= line.len) if (line[i] ==
//! delimiter)` — Scanner.splitInto, Scanner.splitOwned, and three worker
//! contexts in parallel.zig. Five copies of a splitter means five places
//! for the single-threaded and parallel paths to disagree about what a
//! row even contains, which is exactly the failure the cross-client
//! differential test exists to catch. Quoting is added here once.
//!
//! ## What is supported
//!
//! RFC 4180 quoting, minus embedded newlines:
//!
//!   * A field is quoted only if its FIRST byte is `"`. `he said "hi"`
//!     is an ordinary unquoted field containing quote characters, and is
//!     returned byte-for-byte — quotes are not special in the middle of
//!     an unquoted field.
//!   * Inside a quoted field the delimiter is data: `1,"Smith, John",UK`
//!     is three fields, not four.
//!   * `""` inside a quoted field is one literal `"`.
//!
//! ## What is NOT supported, and why it now fails loudly
//!
//! A quoted field containing a NEWLINE. The reader is line-oriented
//! (chunked reads split on `\n`) and the parallel path divides the file
//! into byte ranges aligned to newlines — a record spanning lines would
//! be torn in half by the range split, and no amount of care in this
//! function can put it back together. Rather than return the two halves
//! as if they were rows, an unterminated quote is now
//! `error.UnterminatedQuote`: a loud failure on a file this reader
//! cannot represent, instead of silently wrong fields.
const std = @import("std");
const Allocator = std.mem.Allocator;
const InputLimits = @import("input_limits.zig").InputLimits;

pub const SplitError = error{UnterminatedQuote} || Allocator.Error || @import("input_limits.zig").LimitError;

/// Walks the fields of one CSV record.
///
/// Fields are zero-copy slices into `line`. The single exception is a
/// quoted field containing `""`, which has to be unescaped somewhere:
/// those are built in `scratch`.
///
/// `scratch` is grown at most once per line, on the first escaped field,
/// to the whole line's length. That is enough for every escaped field on
/// the line put together (unescaping only ever shrinks), so no later
/// append can reallocate and invalidate a slice already handed out. It
/// also means a line with no `""` in it — every line, in every file
/// anyone has benchmarked — does not allocate at all.
pub const FieldIterator = struct {
    limits: InputLimits = InputLimits.unlimited,
    fields_read: usize = 0,
    line: []const u8,
    delimiter: u8,
    allocator: Allocator,
    scratch: *std.ArrayListUnmanaged(u8),
    pos: usize = 0,
    done: bool = false,

    pub fn init(
        allocator: Allocator,
        line: []const u8,
        delimiter: u8,
        scratch: *std.ArrayListUnmanaged(u8),
    ) SplitError!FieldIterator {
        return initWithLimits(allocator, line, delimiter, scratch, InputLimits.unlimited);
    }

    pub fn initWithLimits(
        allocator: Allocator,
        line: []const u8,
        delimiter: u8,
        scratch: *std.ArrayListUnmanaged(u8),
        limits: InputLimits,
    ) SplitError!FieldIterator {
        try limits.checkRecord(0, line.len);
        scratch.clearRetainingCapacity();
        return .{ .line = line, .delimiter = delimiter, .allocator = allocator, .scratch = scratch, .limits = limits };
    }

    /// Inline on purpose: this is the per-field hot loop of every CSV
    /// path in the library, and the quoted case is a cold out-of-line
    /// call away.
    pub inline fn next(self: *FieldIterator) SplitError!?[]const u8 {
        if (self.done) return null;
        try self.limits.checkField(self.fields_read);
        self.fields_read += 1;
        const line = self.line;
        const start = self.pos;

        // An empty line is one empty field, matching what the unquoted
        // splitter this replaces returned.
        if (start >= line.len) {
            self.done = true;
            return line[line.len..];
        }

        // One compare, at the field's first byte only — a quote
        // anywhere else is ordinary data, so there is nothing to scan
        // for ahead of time. An up-front memchr of the whole line was
        // tried and is worse: it re-reads columns that a projection with
        // stop_after_column would never have touched (+7-9% on a
        // two-column projection over a ten-column file).
        if (line[start] == '"') return try self.quotedField();

        // Unquoted: everything up to the next delimiter, verbatim.
        // Deliberately a byte loop and not std.mem.indexOfScalarPos:
        // real CSV fields are a handful of bytes, and the vector
        // routine's setup cost swamps the scan at that length —
        // measured at +20-32% on a 130MB scan versus this loop.
        var i = start;
        while (i < line.len) : (i += 1) {
            if (line[i] == self.delimiter) {
                self.pos = i + 1;
                return line[start..i];
            }
        }
        self.done = true;
        return line[start..];
    }

    fn quotedField(self: *FieldIterator) SplitError!?[]const u8 {
        const line = self.line;
        const open = self.pos + 1;

        // Fast path: a quoted field with no doubled quote inside needs no
        // unescaping at all, so it stays a zero-copy slice of the line.
        const i = open;
        while (std.mem.indexOfScalarPos(u8, line, i, '"')) |q| {
            if (q + 1 < line.len and line[q + 1] == '"') {
                // Doubled quote — this field needs unescaping; restart
                // and build it in scratch.
                return try self.quotedFieldEscaped(open);
            }
            self.advancePastFieldEnd(q + 1);
            return line[open..q];
        }
        // No closing quote anywhere on this line: the record either spans
        // lines (unsupported, see the file comment) or the file is
        // malformed. Either way it is not something to guess at.
        return SplitError.UnterminatedQuote;
    }

    fn quotedFieldEscaped(self: *FieldIterator, open: usize) SplitError!?[]const u8 {
        const line = self.line;
        // The one reservation for this line. items.len is 0 on the first
        // escaped field of the line (init cleared it), so growing here
        // cannot invalidate anything; on later escaped fields the
        // capacity already covers the rest of the line and this is a
        // compare.
        try self.scratch.ensureTotalCapacity(self.allocator, line.len);
        const out_start = self.scratch.items.len;
        var i = open;
        while (i < line.len) {
            if (line[i] == '"') {
                if (i + 1 < line.len and line[i + 1] == '"') {
                    self.scratch.appendAssumeCapacity('"');
                    i += 2;
                    continue;
                }
                self.advancePastFieldEnd(i + 1);
                return self.scratch.items[out_start..];
            }
            self.scratch.appendAssumeCapacity(line[i]);
            i += 1;
        }
        return SplitError.UnterminatedQuote;
    }

    /// After a quoted field's closing quote, the record continues at the
    /// next delimiter. Anything between the two (stray whitespace from a
    /// sloppy writer) is dropped rather than treated as a new field.
    fn advancePastFieldEnd(self: *FieldIterator, after_quote: usize) void {
        if (std.mem.indexOfScalarPos(u8, self.line, after_quote, self.delimiter)) |d| {
            self.pos = d + 1;
            if (self.pos > self.line.len) self.done = true;
        } else {
            self.done = true;
            self.pos = self.line.len;
        }
    }
};

/// Writes one field, adding RFC 4180 quoting when the field cannot be
/// written bare. This is the inverse of FieldIterator: now that the
/// reader unquotes fields, a CSV writer that emitted them verbatim would
/// turn `Smith, John` back into two fields and lose data on a round
/// trip. Quoting is applied only where it is needed, so ordinary files
/// come out byte-identical to their input.
pub fn writeField(out: *std.io.Writer, field: []const u8, delimiter: u8) !void {
    if (std.mem.indexOfScalar(u8, field, delimiter) == null and
        std.mem.indexOfAny(u8, field, "\"\r\n") == null)
    {
        return out.writeAll(field);
    }
    try out.writeByte('"');
    var rest = field;
    while (std.mem.indexOfScalar(u8, rest, '"')) |q| {
        try out.writeAll(rest[0 .. q + 1]);
        try out.writeByte('"'); // doubled, per RFC 4180
        rest = rest[q + 1 ..];
    }
    try out.writeAll(rest);
    try out.writeByte('"');
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn collect(allocator: Allocator, line: []const u8, delim: u8) ![][]const u8 {
    var scratch: std.ArrayListUnmanaged(u8) = .{};
    defer scratch.deinit(allocator);
    var out: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer out.deinit(allocator);
    var it = try FieldIterator.init(allocator, line, delim, &scratch);
    while (try it.next()) |f| try out.append(allocator, try allocator.dupe(u8, f));
    return out.toOwnedSlice(allocator);
}

fn freeFields(allocator: Allocator, fields: [][]const u8) void {
    for (fields) |f| allocator.free(f);
    allocator.free(fields);
}

test "unquoted rows split exactly as before" {
    const f = try collect(testing.allocator, "1,Alice,London", ',');
    defer freeFields(testing.allocator, f);
    try testing.expectEqual(@as(usize, 3), f.len);
    try testing.expectEqualStrings("1", f[0]);
    try testing.expectEqualStrings("Alice", f[1]);
    try testing.expectEqualStrings("London", f[2]);
}

test "empty fields, leading, trailing and consecutive" {
    const f = try collect(testing.allocator, ",a,,b,", ',');
    defer freeFields(testing.allocator, f);
    try testing.expectEqual(@as(usize, 5), f.len);
    try testing.expectEqualStrings("", f[0]);
    try testing.expectEqualStrings("a", f[1]);
    try testing.expectEqualStrings("", f[2]);
    try testing.expectEqualStrings("b", f[3]);
    try testing.expectEqualStrings("", f[4]);
}

test "an empty line is a single empty field" {
    const f = try collect(testing.allocator, "", ',');
    defer freeFields(testing.allocator, f);
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqualStrings("", f[0]);
}

test "a quoted field may contain the delimiter" {
    // The whole point: this is three fields, not four.
    const f = try collect(testing.allocator, "1,\"Smith, John\",London", ',');
    defer freeFields(testing.allocator, f);
    try testing.expectEqual(@as(usize, 3), f.len);
    try testing.expectEqualStrings("1", f[0]);
    try testing.expectEqualStrings("Smith, John", f[1]);
    try testing.expectEqualStrings("London", f[2]);
}

test "doubled quotes inside a quoted field become one literal quote" {
    const f = try collect(testing.allocator, "1,\"He said \"\"hi\"\"\",x", ',');
    defer freeFields(testing.allocator, f);
    try testing.expectEqual(@as(usize, 3), f.len);
    try testing.expectEqualStrings("He said \"hi\"", f[1]);
    try testing.expectEqualStrings("x", f[2]);
}

test "several escaped fields on one line stay valid together" {
    // Regression guard for the scratch buffer: every unescaped field
    // lives in it, so a reallocation partway through would invalidate an
    // earlier field's slice. Capacity is reserved for the whole line up
    // front precisely to make that impossible.
    const f = try collect(testing.allocator, "\"a\"\"b\",\"c\"\"d\",\"e\"\"f\"", ',');
    defer freeFields(testing.allocator, f);
    try testing.expectEqual(@as(usize, 3), f.len);
    try testing.expectEqualStrings("a\"b", f[0]);
    try testing.expectEqualStrings("c\"d", f[1]);
    try testing.expectEqualStrings("e\"f", f[2]);
}

test "quotes in the middle of an unquoted field are ordinary data" {
    const f = try collect(testing.allocator, "1,he said \"hi\",x", ',');
    defer freeFields(testing.allocator, f);
    try testing.expectEqual(@as(usize, 3), f.len);
    try testing.expectEqualStrings("he said \"hi\"", f[1]);
}

test "an empty quoted field is an empty field" {
    const f = try collect(testing.allocator, "a,\"\",b", ',');
    defer freeFields(testing.allocator, f);
    try testing.expectEqual(@as(usize, 3), f.len);
    try testing.expectEqualStrings("", f[1]);
}

test "a quoted field at end of line, with and without a trailing delimiter" {
    {
        const f = try collect(testing.allocator, "a,\"b,c\"", ',');
        defer freeFields(testing.allocator, f);
        try testing.expectEqual(@as(usize, 2), f.len);
        try testing.expectEqualStrings("b,c", f[1]);
    }
    {
        const f = try collect(testing.allocator, "a,\"b,c\",", ',');
        defer freeFields(testing.allocator, f);
        try testing.expectEqual(@as(usize, 3), f.len);
        try testing.expectEqualStrings("b,c", f[1]);
        try testing.expectEqualStrings("", f[2]);
    }
}

test "an unterminated quote is an error, not a guess" {
    // This is the case the reader genuinely cannot represent (a record
    // spanning lines). Failing loudly is the whole improvement over
    // returning two half-rows.
    var scratch: std.ArrayListUnmanaged(u8) = .{};
    defer scratch.deinit(testing.allocator);
    var it = try FieldIterator.init(testing.allocator, "a,\"unterminated", ',', &scratch);
    _ = try it.next();
    try testing.expectError(SplitError.UnterminatedQuote, it.next());
}

test "a tab delimiter behaves identically" {
    const f = try collect(testing.allocator, "1\t\"a\tb\"\tc", '\t');
    defer freeFields(testing.allocator, f);
    try testing.expectEqual(@as(usize, 3), f.len);
    try testing.expectEqualStrings("a\tb", f[1]);
}

test "a line with no escaped field never allocates" {
    // The hot path: an allocator that fails on its very first call is
    // enough to prove quote-free (and plain-quoted) lines never touch it.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const a = failing.allocator();
    var scratch: std.ArrayListUnmanaged(u8) = .{};
    defer scratch.deinit(a);

    for ([_][]const u8{ "1,Alice,London", "1,\"Smith, John\",UK", "a,,b" }) |line| {
        var it = try FieldIterator.init(a, line, ',', &scratch);
        while (try it.next()) |_| {}
    }
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

fn writeToString(allocator: Allocator, field: []const u8, delimiter: u8) ![]u8 {
    var w: std.io.Writer.Allocating = .init(allocator);
    errdefer w.deinit();
    try writeField(&w.writer, field, delimiter);
    return w.toOwnedSlice();
}

test "writeField quotes only what has to be quoted" {
    const a = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "plain", "plain" },
        .{ "", "" },
        .{ "Smith, John", "\"Smith, John\"" },
        .{ "he said \"hi\"", "\"he said \"\"hi\"\"\"" },
        .{ "two\nlines", "\"two\nlines\"" },
        .{ "cr\rhere", "\"cr\rhere\"" },
    };
    for (cases) |c| {
        const got = try writeToString(a, c[0], ',');
        defer a.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "a field survives a write/read round trip" {
    const a = testing.allocator;
    const originals = [_][]const u8{ "plain", "", "Smith, John", "he said \"hi\"", "\"leading quote", "a\"\"b" };
    for (originals) |orig| {
        const encoded = try writeToString(a, orig, ',');
        defer a.free(encoded);
        const fields = try collect(a, encoded, ',');
        defer freeFields(a, fields);
        try testing.expectEqual(@as(usize, 1), fields.len);
        try testing.expectEqualStrings(orig, fields[0]);
    }
}
