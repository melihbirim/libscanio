//! libscanio M2: filter, projection, limit, first, count — composed on top
//! of M1's Scanner rather than added to it, so the tested scan primitive
//! stays untouched.
//!
//! The guiding rule here is work not done, not work done faster:
//! - limit/first stop pulling from the Scanner the instant enough rows
//!   are found — no over-read, no discarding extra rows after the fact.
//! - count() with no WHERE clause never splits a single row into fields;
//!   it counts newlines directly on the mapped bytes. Counting rows and
//!   parsing rows are different amounts of work, and this is the one case
//!   where nothing about the row's contents needs to be known at all.
//! - projection narrows the field slice handed back per row; it does not
//!   avoid splitting (the raw scan already has to find every delimiter to
//!   find the *requested* columns' boundaries), but it does avoid copying
//!   or allocating anything beyond that existing split.
const std = @import("std");
const Allocator = std.mem.Allocator;
const scan = @import("root.zig");
const Scanner = scan.Scanner;
const Row = scan.Row;

pub const Op = enum { eq, neq, gt, gte, lt, lte };

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
};

pub const Query = struct {
    scanner: Scanner,
    columns: ?[]const usize,
    where: []const Predicate,
    limit: ?usize,
    returned: usize = 0,
    /// Reused across next() calls when columns != null, same
    /// grow-not-reallocate discipline as Scanner's own field_buf.
    proj_buf: []const []const u8 = &.{},

    pub fn open(allocator: Allocator, path: []const u8, options: QueryOptions) !Query {
        const scanner = try Scanner.open(allocator, path);
        return .{ .scanner = scanner, .columns = options.columns, .where = options.where, .limit = options.limit };
    }

    pub fn deinit(self: *Query) void {
        if (self.proj_buf.len > 0) self.scanner.allocator.free(@constCast(self.proj_buf));
        self.scanner.deinit();
    }

    pub fn columnIndex(self: Query, name: []const u8) ?usize {
        return self.scanner.columnIndex(name);
    }

    /// Next matching, projected row — or null once the limit is reached
    /// or the file is exhausted, whichever comes first.
    pub fn next(self: *Query) !?Row {
        if (self.limit) |lim| {
            if (self.returned >= lim) return null;
        }
        while (try self.scanner.next()) |row| {
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
            var n: usize = 0;
            var start: usize = self.scanner.pos;
            for (self.scanner.data[start..]) |c| {
                if (c == '\n') n += 1;
            }
            // A final row with no trailing newline still counts.
            if (self.scanner.data.len > start and self.scanner.data[self.scanner.data.len - 1] != '\n') n += 1;
            self.scanner.pos = self.scanner.data.len;
            _ = &start;
            return n;
        }
        var n: usize = 0;
        while (try self.scanner.next()) |row| {
            if (matches(row, self.where)) n += 1;
        }
        return n;
    }

    fn project(self: *Query, row: Row) Row {
        const cols = self.columns orelse return row;
        if (self.proj_buf.len < cols.len) {
            const grown = self.scanner.allocator.realloc(@constCast(self.proj_buf), cols.len) catch return row;
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
