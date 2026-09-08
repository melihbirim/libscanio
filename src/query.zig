//! libscanio M2 + M4: filter, projection, limit, first, count — composed
//! on top of either Scanner (CSV) or NdjsonScanner, so callers see nearly
//! the same shape regardless of format. Neither underlying scanner is
//! touched by this file; format-specific logic stays in root.zig/ndjson.zig.
//!
//! The guiding rule here is work not done, not work done faster:
//! - limit/first stop pulling from the source the instant enough rows
//!   are found — no over-read, no discarding extra rows after the fact.
//! - count() with no WHERE clause never splits a single row into fields;
//!   it counts newlines/objects directly against the chunked read buffer.
//!   This is true for both formats — CSV and NDJSON are both
//!   one-record-per-line (or, for JSON arrays, one-object-per-boundary),
//!   so counting records never needs a full field parse either way.
//! - projection narrows the field slice handed back per row; it does not
//!   avoid splitting/parsing (the raw scan already has to find every
//!   field to find the *requested* columns), but it does avoid copying
//!   or allocating anything beyond that existing work.
const std = @import("std");
const Allocator = std.mem.Allocator;
const scan = @import("root.zig");
const Scanner = scan.Scanner;
const NdjsonScanner = scan.NdjsonScanner;
const Row = scan.Row;

pub const Op = enum { eq, neq, gt, gte, lt, lte, in_list };

/// The one place that decides whether a field is "a number" for every
/// comparison, ordering, and aggregate in this library.
///
/// std.fmt.parseFloat alone is not that test: it happily accepts the
/// literal text "nan", "inf" and "-inf", and the f64 it returns then
/// poisons everything downstream. NaN compares false against every
/// value including itself, so a single such cell made min/max stick
/// forever (aggregate.zig), turned sort order non-transitive
/// (order.zig's compareField returned .eq for a NaN against every row),
/// and let a NaN key sit in the top-K heap that nothing could ever
/// evict (topk.zig). Non-finite text is data, not arithmetic — treated
/// as non-numeric here, which is exactly the "skip what isn't a usable
/// number / fall back to a string compare" rule all four callers
/// already meant to implement.
pub fn parseNumeric(s: []const u8) ?f64 {
    const v = std.fmt.parseFloat(f64, s) catch return null;
    if (!std.math.isFinite(v)) return null;
    return v;
}

pub const Format = enum { csv, ndjson };

pub const Predicate = struct {
    column: usize,
    op: Op,
    value: []const u8 = "",
    /// Only used when op == .in_list — the set of values to match
    /// against. Empty/unused for every other op.
    values: []const []const u8 = &.{},
    /// Precomputed once at Query.open() time, not re-parsed per row.
    numeric_value: ?f64 = null,

    pub fn init(column: usize, op: Op, value: []const u8) Predicate {
        return .{ .column = column, .op = op, .value = value, .numeric_value = parseNumeric(value) };
    }

    /// col IN (a, b, c) — matches if the field equals ANY of `values`.
    /// Each value is compared numerically first (if both the field and
    /// that value parse as numbers) then falls back to a string compare,
    /// same per-value logic .eq already uses.
    pub fn initIn(column: usize, values: []const []const u8) Predicate {
        return .{ .column = column, .op = .in_list, .values = values };
    }
};

pub const QueryOptions = struct {
    /// Serial reader limits; recommended is an opt-in protected profile.
    /// Active limits also apply to headers, count(), and projected tails.
    limits: scan.InputLimits = scan.InputLimits.unlimited,
    /// Column indices to keep in each returned row, in order. Null = all columns.
    columns: ?[]const usize = null,
    /// Implicitly AND-ed together. Empty = no filter.
    where: []const Predicate = &.{},
    limit: ?usize = null,
    /// Return the COMPLEMENT of `where` — every row the filter rejects,
    /// instead of every row it accepts. With no `where` at all this
    /// matches nothing (the negation of "keep everything"), which is
    /// unusual enough to be worth stating: `negate` without a filter is
    /// almost always a caller mistake, and returning zero rows is the
    /// honest reading of it rather than a silently ignored flag.
    negate: bool = false,
    /// Null = infer from the path's extension (.ndjson/.jsonl -> ndjson,
    /// anything else -> csv).
    format: ?Format = null,
    /// CSV read-buffer size in bytes. Null = Scanner's default (256KB —
    /// see CHUNK_SIZE in root.zig for the measurements behind that
    /// default).
    csv_chunk_size: ?usize = null,
    /// NDJSON/JSON-array read-buffer size. Null = the same default.
    json_chunk_size: ?usize = null,
    /// Highest column index this Query's caller will actually read —
    /// the max of every WHERE predicate's column and every projected
    /// column (plus, for aggregate()/topk()-style single-column callers,
    /// whatever column they'll read). Null (default) means "don't know,
    /// split every field" — always correct, just not always fastest.
    /// Honoured by both formats. CSV stops splitting the line's bytes
    /// (see stop_after_column in ScannerOptions, root.zig); NDJSON stops
    /// walking the row's keys, which is worth more there than the note
    /// here once claimed — a 2-of-8-column read is ~7x cheaper in the
    /// fast path. Either way the returned Row is truncated to the bound,
    /// so a caller must not ask for a column above it. This is NOT
    /// auto-computed from `columns`/`where` here, on purpose: a caller
    /// like aggregate()/topk() reads a column that's only known at the
    /// call to aggregate()/topk() itself, after Query.open() already
    /// ran — the bound has to come from whoever knows all the columns
    /// that will ever be read, which isn't always this struct alone.
    stop_after_column: ?usize = null,
};

pub fn inferFormat(path: []const u8) Format {
    // .json routes here too, not just .ndjson/.jsonl: NdjsonScanner
    // sniffs array-vs-line-delimited from content, since a .json file
    // could legitimately be either.
    if (std.mem.endsWith(u8, path, ".ndjson") or std.mem.endsWith(u8, path, ".jsonl") or std.mem.endsWith(u8, path, ".json")) return .ndjson;
    return .csv;
}

const Source = union(Format) {
    csv: Scanner,
    ndjson: NdjsonScanner,

    fn deinit(self: *Source) void {
        switch (self.*) {
            .csv => |*s| s.deinit(),
            .ndjson => |*s| s.deinit(),
        }
    }

    fn next(self: *Source) !?Row {
        return switch (self.*) {
            .csv => |*s| s.next(),
            .ndjson => |*s| s.next(),
        };
    }

    fn columnIndex(self: Source, name: []const u8) ?usize {
        return switch (self) {
            .csv => |s| s.columnIndex(name),
            .ndjson => |s| s.columnIndex(name),
        };
    }

    fn header(self: Source) [][]const u8 {
        return switch (self) {
            .csv => |s| s.header,
            .ndjson => |s| s.header,
        };
    }

    fn allocator(self: Source) Allocator {
        return switch (self) {
            .csv => |s| s.allocator,
            .ndjson => |s| s.allocator,
        };
    }

    /// Fast path for count() with no WHERE clause — never splits/parses a
    /// field. Both CSV and NDJSON count through their chunked read
    /// buffers, bounded memory either way.
    fn countFastPath(self: *Source) !usize {
        return switch (self.*) {
            .csv => |*s| s.countRemaining(),
            .ndjson => |*s| s.countRemaining(),
        };
    }
};

pub const Query = struct {
    source: Source,
    columns: ?[]const usize,
    where: []const Predicate,
    negate: bool = false,
    limit: ?usize,
    returned: usize = 0,
    /// Reused across next() calls when columns != null, same
    /// grow-not-reallocate discipline as the scanners' own buffers.
    proj_buf: []const []const u8 = &.{},

    pub fn open(allocator: Allocator, path: []const u8, options: QueryOptions) !Query {
        const format = options.format orelse inferFormat(path);
        const source: Source = switch (format) {
            .csv => .{ .csv = try Scanner.openWithOptions(allocator, path, .{
                .limits = options.limits,
                .chunk_size = options.csv_chunk_size orelse scan.default_chunk_size,
                .stop_after_column = options.stop_after_column,
            }) },
            .ndjson => blk: {
                var nd = try NdjsonScanner.openWithOptions(allocator, path, .{
                    .limits = options.limits,
                    .chunk_size = options.json_chunk_size orelse scan.default_chunk_size,
                });
                nd.setStopAfterColumn(options.stop_after_column);
                break :blk .{ .ndjson = nd };
            },
        };
        return .{
            .source = source,
            .columns = options.columns,
            .where = options.where,
            .negate = options.negate,
            .limit = options.limit,
        };
    }

    pub fn fromBytes(allocator: Allocator, bytes: []const u8, format: Format) !Query {
        return .{
            .source = switch (format) {
                .csv => .{ .csv = try Scanner.fromBytes(allocator, bytes, .{}) },
                .ndjson => .{ .ndjson = try NdjsonScanner.fromBytes(allocator, bytes, .{}) },
            },
            .columns = null,
            .where = &.{},
            .limit = null,
        };
    }

    pub fn deinit(self: *Query) void {
        if (self.proj_buf.len > 0) self.source.allocator().free(@constCast(self.proj_buf));
        self.source.deinit();
    }

    pub fn columnIndex(self: Query, name: []const u8) ?usize {
        return self.source.columnIndex(name);
    }

    pub fn header(self: Query) [][]const u8 {
        return self.source.header();
    }

    /// Next matching, projected row — or null once the limit is reached
    /// or the file is exhausted, whichever comes first.
    pub fn next(self: *Query) !?Row {
        if (self.limit) |lim| {
            if (self.returned >= lim) return null;
        }
        while (try self.source.next()) |row| {
            if (!matches(row, self.where, self.negate)) continue;
            self.returned += 1;
            return self.project(row);
        }
        return null;
    }

    /// First matching row, or null. Equivalent to limit(1) but reads no
    /// more of the file than necessary to find it — same underlying
    /// early-exit next() already does, named for the common case.
    pub fn first(self: *Query) !?Row {
        return self.next();
    }

    /// Row count. With no WHERE clause, this never parses a single field:
    /// it counts record boundaries directly against the chunked read
    /// buffer. With a WHERE clause, rows still have to be split and
    /// matched, but never projected or returned.
    pub fn count(self: *Query) !usize {
        // Remaining budget under this Query's limit, sharing next()'s
        // meaning of `returned` so count() and next() can't disagree
        // about how much of the limit is left. count() used to ignore
        // `limit` entirely on BOTH branches below — a Query opened with
        // .limit = 2 over a 5-row file counted 5.
        const remaining: ?usize = if (self.limit) |lim|
            (if (self.returned >= lim) return 0 else lim - self.returned)
        else
            null;

        // The never-split-a-field fast path is only valid when nothing
        // can stop the scan early: no filter to test and no limit to
        // reach. With a limit, the generic loop below is the cheaper
        // answer anyway for the case that matters (a small limit stops
        // after a few rows instead of counting record boundaries through
        // the whole file).
        // ...and no negation: NOT(keep everything) is zero rows, which
        // the newline-counting path would answer with the row total.
        if (self.where.len == 0 and remaining == null and !self.negate) {
            return self.source.countFastPath();
        }

        var n: usize = 0;
        while (try self.source.next()) |row| {
            if (!matches(row, self.where, self.negate)) continue;
            n += 1;
            self.returned += 1;
            if (remaining) |r| {
                if (n >= r) break;
            }
        }
        return n;
    }

    fn project(self: *Query, row: Row) Row {
        const cols = self.columns orelse return row;
        if (self.proj_buf.len < cols.len) {
            const grown = self.source.allocator().realloc(@constCast(self.proj_buf), cols.len) catch return row;
            self.proj_buf = grown;
        }
        const buf = @constCast(self.proj_buf[0..cols.len]);
        for (cols, 0..) |ci, i| buf[i] = row.get(ci) orelse "";
        return Row{ .fields = buf };
    }
};

/// True if `row` should be kept. `negate` inverts the whole conjunction
/// — NOT(p1 AND p2 AND ...) — which is the complement of the result set,
/// not a general boolean expression. That distinction is the reason this
/// is one flag and not an expression tree: the case that actually needed
/// OR was "give me the rows that FAILED these checks", and the negation
/// of an AND-list covers it exactly.
///
/// `negate` is a required argument rather than a defaulted one on
/// purpose: every call site has to decide, so a new filter path cannot
/// silently ignore it and return the wrong half of the file.
///
/// A row too short to have a predicate's column does not match — so
/// under negation it DOES. That is the right answer for the case this
/// exists for: a truncated row cannot satisfy `amount >= 0`, so it
/// belongs in the rejects.
pub fn matches(row: Row, predicates: []const Predicate, negate: bool) bool {
    var m = true;
    for (predicates) |p| {
        const field = row.get(p.column) orelse {
            m = false;
            break;
        };
        if (!evalOne(field, p)) {
            m = false;
            break;
        }
    }
    return m != negate; // XOR
}

fn evalOne(field: []const u8, p: Predicate) bool {
    if (p.op == .in_list) {
        for (p.values) |v| {
            if (parseNumeric(v)) |pv| {
                if (parseNumeric(field)) |fv| {
                    if (fv == pv) return true;
                    continue;
                }
            }
            if (std.mem.eql(u8, field, v)) return true;
        }
        return false;
    }
    if (p.numeric_value) |pv| {
        if (parseNumeric(field)) |fv| {
            return switch (p.op) {
                .eq => fv == pv,
                .neq => fv != pv,
                .gt => fv > pv,
                .gte => fv >= pv,
                .lt => fv < pv,
                .lte => fv <= pv,
                .in_list => unreachable, // handled above, before this branch
            };
        }
    }
    // Non-numeric field or predicate value: fall back to string compare.
    // Only equality/inequality are well-defined for strings here.
    return switch (p.op) {
        .eq => std.mem.eql(u8, field, p.value),
        .neq => !std.mem.eql(u8, field, p.value),
        .gt => std.mem.order(u8, field, p.value) == .gt,
        .gte => std.mem.order(u8, field, p.value) != .lt,
        .lt => std.mem.order(u8, field, p.value) == .lt,
        .lte => std.mem.order(u8, field, p.value) != .gt,
        .in_list => unreachable, // handled above, before this branch
    };
}

test "filter: single numeric predicate" {
    const allocator = std.testing.allocator;
    const path = "test_query_filter.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n3,900\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .where = &.{Predicate.init(1, .gt, "1000")} });
    defer q.deinit();

    const row = (try q.next()).?;
    try std.testing.expectEqualStrings("2", row.get(0).?);
    try std.testing.expectEqual(@as(?Row, null), try q.next());
}

test "filter: IN matches any of several values" {
    const allocator = std.testing.allocator;
    const path = "test_query_in.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,color\n1,red\n2,yellow\n3,blue\n4,green\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .where = &.{
        Predicate.initIn(1, &.{ "yellow", "green" }),
    } });
    defer q.deinit();

    const row1 = (try q.next()).?;
    try std.testing.expectEqualStrings("2", row1.get(0).?);
    const row2 = (try q.next()).?;
    try std.testing.expectEqualStrings("4", row2.get(0).?);
    try std.testing.expectEqual(@as(?Row, null), try q.next());
}

test "filter: IN composes with AND" {
    const allocator = std.testing.allocator;
    const path = "test_query_in_and.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,color,amount\n1,yellow,50\n2,yellow,1500\n3,green,1500\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .where = &.{
        Predicate.initIn(1, &.{ "yellow", "green" }),
        Predicate.init(2, .gt, "1000"),
    } });
    defer q.deinit();

    const row1 = (try q.next()).?;
    try std.testing.expectEqualStrings("2", row1.get(0).?);
    const row2 = (try q.next()).?;
    try std.testing.expectEqualStrings("3", row2.get(0).?);
    try std.testing.expectEqual(@as(?Row, null), try q.next());
}

test "filter: IN matches numerically too" {
    const allocator = std.testing.allocator;
    const path = "test_query_in_numeric.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,rank\n1,1\n2,2\n3,3\n4,4\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .where = &.{
        Predicate.initIn(1, &.{ "1", "3" }),
    } });
    defer q.deinit();

    const row1 = (try q.next()).?;
    try std.testing.expectEqualStrings("1", row1.get(0).?);
    const row2 = (try q.next()).?;
    try std.testing.expectEqualStrings("3", row2.get(0).?);
    try std.testing.expectEqual(@as(?Row, null), try q.next());
}

test "filter: two predicates are ANDed" {
    const allocator = std.testing.allocator;
    const path = "test_query_and.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,city,amount\n1,Austin,50\n2,Austin,1500\n3,Denver,1500\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .where = &.{
        Predicate.init(1, .eq, "Austin"),
        Predicate.init(2, .gt, "1000"),
    } });
    defer q.deinit();

    const row = (try q.next()).?;
    try std.testing.expectEqualStrings("2", row.get(0).?);
    try std.testing.expectEqual(@as(?Row, null), try q.next());
}

test "stop_after_column composes with WHERE and projection: trailing unread columns never split" {
    const allocator = std.testing.allocator;
    const path = "test_query_stop_after_column.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,city,amount,notes,extra\n1,Austin,50,x,y\n2,Austin,1500,x,y\n3,Denver,1500,x,y\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    // Needs columns 0 (projected) and 1,2 (WHERE) — highest is 2, so
    // stop_after_column=2 should still work correctly even though
    // "notes"/"extra" (columns 3,4) are never split.
    var q = try Query.open(allocator, path, .{
        .columns = &.{0},
        .where = &.{
            Predicate.init(1, .eq, "Austin"),
            Predicate.init(2, .gt, "1000"),
        },
        .stop_after_column = 2,
    });
    defer q.deinit();

    const row = (try q.next()).?;
    try std.testing.expectEqualStrings("2", row.get(0).?);
    try std.testing.expectEqual(@as(?Row, null), try q.next());
}

test "projection: only requested columns come back, in requested order" {
    const allocator = std.testing.allocator;
    const path = "test_query_proj.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,name,amount\n1,Alice,50\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .columns = &.{ 2, 0 } });
    defer q.deinit();

    const row = (try q.next()).?;
    try std.testing.expectEqual(@as(usize, 2), row.fields.len);
    try std.testing.expectEqualStrings("50", row.get(0).?);
    try std.testing.expectEqualStrings("1", row.get(1).?);
}

test "limit: stops after N matching rows" {
    const allocator = std.testing.allocator;
    const path = "test_query_limit.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id\n1\n2\n3\n4\n5\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .limit = 2 });
    defer q.deinit();

    var seen: usize = 0;
    while (try q.next()) |_| seen += 1;
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "first: returns the first matching row and nothing more" {
    const allocator = std.testing.allocator;
    const path = "test_query_first.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,10\n2,2000\n3,3000\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .where = &.{Predicate.init(1, .gt, "1000")} });
    defer q.deinit();

    const row = (try q.first()).?;
    try std.testing.expectEqualStrings("2", row.get(0).?);
}

test "count: no filter takes the newline-counting fast path" {
    const allocator = std.testing.allocator;
    const path = "test_query_count.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id\n1\n2\n3\n4\n5\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    try std.testing.expectEqual(@as(usize, 5), try q.count());
}

test "count: with filter counts only matching rows" {
    const allocator = std.testing.allocator;
    const path = "test_query_count_filtered.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n3,2500\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .where = &.{Predicate.init(1, .gt, "1000")} });
    defer q.deinit();

    try std.testing.expectEqual(@as(usize, 2), try q.count());
}

test "count: no trailing newline still counts the last row" {
    const allocator = std.testing.allocator;
    const path = "test_query_count_no_trailing_nl.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id\n1\n2\n3" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    try std.testing.expectEqual(@as(usize, 3), try q.count());
}

test "ndjson: format inferred from .ndjson extension, filter+project+limit work identically to csv" {
    const allocator = std.testing.allocator;
    const path = "test_query_ndjson.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"id":1,"city":"Austin","amount":50}
        \\{"id":2,"city":"Austin","amount":1500}
        \\{"id":3,"city":"Denver","amount":2500}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{
        .columns = &.{ 0, 2 },
        .where = &.{Predicate.init(2, .gt, "1000")},
        .limit = 1,
    });
    defer q.deinit();

    const row = (try q.next()).?;
    try std.testing.expectEqualStrings("2", row.get(0).?);
    try std.testing.expectEqualStrings("1500", row.get(1).?);
    try std.testing.expectEqual(@as(?Row, null), try q.next());
}

test "ndjson: count() fast path works the same as csv" {
    const allocator = std.testing.allocator;
    const path = "test_query_ndjson_count.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"id":1}
        \\{"id":2}
        \\{"id":3}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();
    try std.testing.expectEqual(@as(usize, 3), try q.count());
}

test "format override: .jsonl content opened with a non-matching extension via explicit format" {
    const allocator = std.testing.allocator;
    const path = "test_query_format_override.txt";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "{\"id\":1}\n{\"id\":2}\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .format = .ndjson });
    defer q.deinit();
    const row = (try q.next()).?;
    try std.testing.expectEqualStrings("1", row.get(0).?);
}

test "json array: .json file sniffed and read via the same NDJSON pipeline, filter+project+limit work" {
    const allocator = std.testing.allocator;
    const path = "test_query_json_array.json";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\[
        \\  {"id": 1, "city": "Austin", "amount": 50},
        \\  {"id": 2, "city": "Austin", "amount": 1500},
        \\  {"id": 3, "city": "Denver", "amount": 2500}
        \\]
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{
        .columns = &.{ 0, 2 },
        .where = &.{Predicate.init(1, .eq, "Austin")},
    });
    defer q.deinit();

    const row1 = (try q.next()).?;
    try std.testing.expectEqualStrings("1", row1.get(0).?);
    try std.testing.expectEqualStrings("50", row1.get(1).?);
    const row2 = (try q.next()).?;
    try std.testing.expectEqualStrings("2", row2.get(0).?);
    try std.testing.expectEqual(@as(?Row, null), try q.next());
}

test "json array: count() fast path still applies (each element becomes one line)" {
    const allocator = std.testing.allocator;
    const path = "test_query_json_array_count.json";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "[{\"id\":1},{\"id\":2},{\"id\":3}]" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();
    try std.testing.expectEqual(@as(usize, 3), try q.count());
}

test "count: respects limit on both the fast path and the filtered path" {
    // count() used to bypass the limit entirely: the no-WHERE branch
    // counted every record boundary in the file and the WHERE branch
    // counted every match, neither stopping at the limit next() honours.
    const allocator = std.testing.allocator;
    const path = "test_query_count_limit.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n3,2500\n4,20\n5,3000\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    {
        var q = try Query.open(allocator, path, .{ .limit = 2 });
        defer q.deinit();
        try std.testing.expectEqual(@as(usize, 2), try q.count());
    }
    {
        var q = try Query.open(allocator, path, .{});
        defer q.deinit();
        try std.testing.expectEqual(@as(usize, 5), try q.count());
    }
    {
        const preds = [_]Predicate{Predicate.init(1, .gt, "1000")};
        var q = try Query.open(allocator, path, .{ .where = &preds, .limit = 1 });
        defer q.deinit();
        try std.testing.expectEqual(@as(usize, 1), try q.count());
    }
    {
        const preds = [_]Predicate{Predicate.init(1, .gt, "1000")};
        var q = try Query.open(allocator, path, .{ .where = &preds });
        defer q.deinit();
        try std.testing.expectEqual(@as(usize, 3), try q.count());
    }
    // A limit already spent by next() leaves nothing for count().
    {
        var q = try Query.open(allocator, path, .{ .limit = 1 });
        defer q.deinit();
        _ = try q.next();
        try std.testing.expectEqual(@as(usize, 0), try q.count());
    }
}

test "parseNumeric: non-finite text is data, not arithmetic" {
    try std.testing.expectEqual(@as(?f64, 42.5), parseNumeric("42.5"));
    try std.testing.expectEqual(@as(?f64, null), parseNumeric("nan"));
    try std.testing.expectEqual(@as(?f64, null), parseNumeric("inf"));
    try std.testing.expectEqual(@as(?f64, null), parseNumeric("-inf"));
    try std.testing.expectEqual(@as(?f64, null), parseNumeric("Infinity"));
    try std.testing.expectEqual(@as(?f64, null), parseNumeric("hello"));
}

test "negate returns exactly the rows the filter rejects" {
    const allocator = std.testing.allocator;
    const path = "test_negate.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,city\n1,London\n2,Paris\n3,London\n4,Berlin\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const preds = [_]Predicate{Predicate.init(1, .eq, "London")};

    var kept = try Query.open(allocator, path, .{ .where = &preds });
    defer kept.deinit();
    var rejected = try Query.open(allocator, path, .{ .where = &preds, .negate = true });
    defer rejected.deinit();

    try std.testing.expectEqual(@as(usize, 2), try kept.count());
    try std.testing.expectEqual(@as(usize, 2), try rejected.count());

    // The two halves partition the file: every row is in exactly one.
    var all = try Query.open(allocator, path, .{});
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 4), try all.count());

    var it = try Query.open(allocator, path, .{ .where = &preds, .negate = true });
    defer it.deinit();
    const r1 = (try it.next()).?;
    try std.testing.expectEqualStrings("Paris", r1.get(1).?);
    const r2 = (try it.next()).?;
    try std.testing.expectEqualStrings("Berlin", r2.get(1).?);
    try std.testing.expectEqual(@as(?Row, null), try it.next());
}

test "negate with no filter matches nothing, rather than silently counting every row" {
    // NOT(keep everything) is zero rows. The newline-counting fast path
    // would answer with the row total, so it has to be skipped here —
    // this is the test that says so.
    const allocator = std.testing.allocator;
    const path = "test_negate_empty.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "a\n1\n2\n3\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .negate = true });
    defer q.deinit();
    try std.testing.expectEqual(@as(usize, 0), try q.count());

    var it = try Query.open(allocator, path, .{ .negate = true });
    defer it.deinit();
    try std.testing.expectEqual(@as(?Row, null), try it.next());
}

test "a row too short to test the column counts as rejected" {
    // It cannot satisfy the predicate, so it belongs in the complement —
    // which is the answer an import wants: a truncated row is a reject,
    // not a silent pass.
    const allocator = std.testing.allocator;
    const path = "test_negate_ragged.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "a,b\n1,10\n2\n3,30\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const preds = [_]Predicate{Predicate.init(1, .gte, "0")};
    var kept = try Query.open(allocator, path, .{ .where = &preds });
    defer kept.deinit();
    var rejected = try Query.open(allocator, path, .{ .where = &preds, .negate = true });
    defer rejected.deinit();
    try std.testing.expectEqual(@as(usize, 2), try kept.count());
    try std.testing.expectEqual(@as(usize, 1), try rejected.count());
}

test "negate composes with projection and limit" {
    const allocator = std.testing.allocator;
    const path = "test_negate_proj.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,city\n1,London\n2,Paris\n3,Berlin\n4,Madrid\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const preds = [_]Predicate{Predicate.init(1, .eq, "London")};
    const cols = [_]usize{1};
    var q = try Query.open(allocator, path, .{ .where = &preds, .negate = true, .columns = &cols, .limit = 2 });
    defer q.deinit();

    const r1 = (try q.next()).?;
    try std.testing.expectEqual(@as(usize, 1), r1.fields.len);
    try std.testing.expectEqualStrings("Paris", r1.get(0).?);
    _ = (try q.next()).?;
    try std.testing.expectEqual(@as(?Row, null), try q.next()); // limit reached
}

test "negate is honoured for NDJSON too, not just CSV" {
    const allocator = std.testing.allocator;
    const path = "test_negate.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data =
        \\{"id": 1, "city": "London"}
        \\{"id": 2, "city": "Paris"}
        \\{"id": 3, "city": "London"}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    const preds = [_]Predicate{Predicate.init(1, .eq, "London")};
    var q = try Query.open(allocator, path, .{ .where = &preds, .negate = true });
    defer q.deinit();
    try std.testing.expectEqual(@as(usize, 1), try q.count());
}

test "matches(): the flag is XOR over the whole conjunction" {
    const fields = [_][]const u8{ "1", "London" };
    const row = Row{ .fields = &fields };
    const hit = [_]Predicate{Predicate.init(1, .eq, "London")};
    const miss = [_]Predicate{Predicate.init(1, .eq, "Paris")};

    try std.testing.expect(matches(row, &hit, false));
    try std.testing.expect(!matches(row, &hit, true));
    try std.testing.expect(!matches(row, &miss, false));
    try std.testing.expect(matches(row, &miss, true));
    // Empty predicate list: keeps everything, so its negation keeps none.
    try std.testing.expect(matches(row, &.{}, false));
    try std.testing.expect(!matches(row, &.{}, true));
}
