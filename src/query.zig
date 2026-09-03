//! libscanio M2 + M4: filter, projection, limit, first, count — composed
//! on top of either Scanner (CSV) or NdjsonScanner, so callers see nearly
//! the same shape regardless of format. Neither underlying scanner is
//! touched by this file; format-specific logic stays in root.zig/ndjson.zig.
//!
//! The guiding rule here is work not done, not work done faster:
//! - limit/first stop pulling from the source the instant enough rows
//!   are found — no over-read, no discarding extra rows after the fact.
//! - count() with no WHERE clause never splits a single row into fields;
//!   it counts newlines directly on the mapped bytes. This is true for
//!   both formats — CSV and NDJSON are both one-record-per-line, so
//!   counting records is exactly counting newlines either way.
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

pub const Op = enum { eq, neq, gt, gte, lt, lte };

pub const Format = enum { csv, ndjson };

pub const Predicate = struct {
    column: usize,
    op: Op,
    value: []const u8,
    /// Precomputed once at Query.open() time, not re-parsed per row.
    numeric_value: ?f64 = null,

    pub fn init(column: usize, op: Op, value: []const u8) Predicate {
        return .{ .column = column, .op = op, .value = value, .numeric_value = std.fmt.parseFloat(f64, value) catch null };
    }
};

pub const QueryOptions = struct {
    /// Column indices to keep in each returned row, in order. Null = all columns.
    columns: ?[]const usize = null,
    /// Implicitly AND-ed together. Empty = no filter.
    where: []const Predicate = &.{},
    limit: ?usize = null,
    /// Null = infer from the path's extension (.ndjson/.jsonl -> ndjson,
    /// anything else -> csv).
    format: ?Format = null,
    /// CSV read-buffer size in bytes. Null = Scanner's default (256KB —
    /// see CHUNK_SIZE in root.zig for the measurements behind that
    /// default). Ignored for NDJSON, which is still fully mmap'd/loaded.
    csv_chunk_size: ?usize = null,
};

fn inferFormat(path: []const u8) Format {
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
    /// field. Both CSV and NDJSON now count through their chunked read
    /// buffers rather than one large mapped/loaded slice.
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
    limit: ?usize,
    returned: usize = 0,
    /// Reused across next() calls when columns != null, same
    /// grow-not-reallocate discipline as the scanners' own buffers.
    proj_buf: []const []const u8 = &.{},

    pub fn open(allocator: Allocator, path: []const u8, options: QueryOptions) !Query {
        const format = options.format orelse inferFormat(path);
        const source: Source = switch (format) {
            .csv => .{ .csv = try Scanner.openWithOptions(allocator, path, .{
                .chunk_size = options.csv_chunk_size orelse scan.default_chunk_size,
            }) },
            .ndjson => .{ .ndjson = try NdjsonScanner.open(allocator, path) },
        };
        return .{ .source = source, .columns = options.columns, .where = options.where, .limit = options.limit };
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
            if (!matches(row, self.where)) continue;
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
    /// it counts '\n' bytes directly in the already-mapped data. With a
    /// WHERE clause, rows still have to be split and matched, but never
    /// projected or returned.
    pub fn count(self: *Query) !usize {
        if (self.where.len == 0) {
            return self.source.countFastPath();
        }
        var n: usize = 0;
        while (try self.source.next()) |row| {
            if (matches(row, self.where)) n += 1;
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

fn matches(row: Row, predicates: []const Predicate) bool {
    for (predicates) |p| {
        const field = row.get(p.column) orelse return false;
        if (!evalOne(field, p)) return false;
    }
    return true;
}

fn evalOne(field: []const u8, p: Predicate) bool {
    if (p.numeric_value) |pv| {
        if (std.fmt.parseFloat(f64, field) catch null) |fv| {
            return switch (p.op) {
                .eq => fv == pv,
                .neq => fv != pv,
                .gt => fv > pv,
                .gte => fv >= pv,
                .lt => fv < pv,
                .lte => fv <= pv,
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
