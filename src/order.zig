//! ORDER BY — single column, v1. Materializes every matching (already
//! WHERE-filtered, already projected by Query) row, then sorts once —
//! not a bounded/external merge-sort. Same tradeoff aggregate()/topK()
//! already accept: peak memory scales with the FILTERED row count, not
//! the file size, which is fine for the common case (a WHERE clause has
//! already cut the result down) and a real, named cost for the
//! unfiltered-full-file case. A bounded/external sort (spill to disk,
//! k-way merge) would keep the bounded-memory guarantee even there, but
//! is real extra engineering, not attempted here — revisit only if a
//! caller actually needs to sort a result set too big to fit in memory.
//!
//! Multi-column (col1 ASC, col2 DESC, ...) also not attempted here —
//! the comparator below takes one column; extending to a slice of
//! (column, descending) tie-break pairs is a small, additive change
//! whenever a caller actually needs tie-breaking, not before.
const std = @import("std");
const Allocator = std.mem.Allocator;
const scan = @import("root.zig");
const Query = scan.Query;
const Row = scan.Row;
const topk_mod = @import("topk.zig");
pub const OwnedRow = topk_mod.OwnedRow;

pub const OrderedRows = struct {
    allocator: Allocator,
    rows: []OwnedRow,

    pub fn deinit(self: OrderedRows) void {
        for (self.rows) |r| r.deinit();
        self.allocator.free(self.rows);
    }
};

/// Numeric-first, string-fallback — same rule query.zig's evalOne()
/// already uses for predicate comparisons, kept consistent rather than
/// inventing a second ordering rule: "10" sorts after "9" (numeric),
/// not before it (which a pure string compare would do).
fn compareField(a: []const u8, b: []const u8) std.math.Order {
    if (std.fmt.parseFloat(f64, a) catch null) |fa| {
        if (std.fmt.parseFloat(f64, b) catch null) |fb| {
            if (fa < fb) return .lt;
            if (fa > fb) return .gt;
            return .eq;
        }
    }
    return std.mem.order(u8, a, b);
}

const SortCtx = struct { column: usize, descending: bool };

fn lessThan(ctx: SortCtx, a: OwnedRow, b: OwnedRow) bool {
    const av = a.get(ctx.column) orelse "";
    const bv = b.get(ctx.column) orelse "";
    const ord = compareField(av, bv);
    return if (ctx.descending) ord == .gt else ord == .lt;
}

/// Drains `q` (its own WHERE/projection/limit already apply — this
/// doesn't re-filter), sorts by `column`. Not a stable sort
/// (std.mem.sort) — ties within equal keys aren't guaranteed to keep
/// their scan order; use std.sort.block if that ever matters to a
/// caller.
pub fn orderBy(allocator: Allocator, q: *Query, column: usize, descending: bool) !OrderedRows {
    var rows: std.ArrayListUnmanaged(OwnedRow) = .{};
    errdefer {
        for (rows.items) |r| r.deinit();
        rows.deinit(allocator);
    }
    while (try q.next()) |row| {
        try rows.append(allocator, try topk_mod.copyRow(allocator, row));
    }
    const owned = try rows.toOwnedSlice(allocator);
    std.mem.sort(OwnedRow, owned, SortCtx{ .column = column, .descending = descending }, lessThan);
    return .{ .allocator = allocator, .rows = owned };
}

test "orderBy: ascending, numeric column" {
    const allocator = std.testing.allocator;
    const path = "test_orderby_asc.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n3,900\n4,3000\n5,200\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    var result = try orderBy(allocator, &q, 1, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 5), result.rows.len);
    try std.testing.expectEqualStrings("1", result.rows[0].get(0).?); // 50
    try std.testing.expectEqualStrings("5", result.rows[1].get(0).?); // 200
    try std.testing.expectEqualStrings("3", result.rows[2].get(0).?); // 900
    try std.testing.expectEqualStrings("2", result.rows[3].get(0).?); // 1500
    try std.testing.expectEqualStrings("4", result.rows[4].get(0).?); // 3000
}

test "orderBy: descending" {
    const allocator = std.testing.allocator;
    const path = "test_orderby_desc.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n3,900\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    var result = try orderBy(allocator, &q, 1, true);
    defer result.deinit();

    try std.testing.expectEqualStrings("2", result.rows[0].get(0).?);
    try std.testing.expectEqualStrings("3", result.rows[1].get(0).?);
    try std.testing.expectEqualStrings("1", result.rows[2].get(0).?);
}

test "orderBy: numeric column sorts numerically, not lexicographically ('9' before '10')" {
    const allocator = std.testing.allocator;
    const path = "test_orderby_numeric_not_lex.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,n\na,10\nb,9\nc,2\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    var result = try orderBy(allocator, &q, 1, false);
    defer result.deinit();

    try std.testing.expectEqualStrings("c", result.rows[0].get(0).?); // 2
    try std.testing.expectEqualStrings("b", result.rows[1].get(0).?); // 9
    try std.testing.expectEqualStrings("a", result.rows[2].get(0).?); // 10
}

test "orderBy: non-numeric column sorts lexicographically" {
    const allocator = std.testing.allocator;
    const path = "test_orderby_string.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,city\n1,Denver\n2,Austin\n3,Boston\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    var result = try orderBy(allocator, &q, 1, false);
    defer result.deinit();

    try std.testing.expectEqualStrings("2", result.rows[0].get(0).?); // Austin
    try std.testing.expectEqualStrings("3", result.rows[1].get(0).?); // Boston
    try std.testing.expectEqualStrings("1", result.rows[2].get(0).?); // Denver
}

test "orderBy: composes with WHERE" {
    const allocator = std.testing.allocator;
    const path = "test_orderby_where.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,city,amount\n1,Austin,50\n2,Denver,3000\n3,Austin,1500\n4,Austin,900\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .where = &.{scan.Predicate.init(1, .eq, "Austin")} });
    defer q.deinit();

    var result = try orderBy(allocator, &q, 2, true);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.rows.len);
    try std.testing.expectEqualStrings("3", result.rows[0].get(0).?); // 1500
    try std.testing.expectEqualStrings("4", result.rows[1].get(0).?); // 900
    try std.testing.expectEqualStrings("1", result.rows[2].get(0).?); // 50
}

test "orderBy: NDJSON works the same as CSV" {
    const allocator = std.testing.allocator;
    const path = "test_orderby_ndjson.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"id":1,"amount":50}
        \\{"id":2,"amount":1500}
        \\{"id":3,"amount":900}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    var result = try orderBy(allocator, &q, 1, false);
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.rows[0].get(0).?);
    try std.testing.expectEqualStrings("3", result.rows[1].get(0).?);
    try std.testing.expectEqualStrings("2", result.rows[2].get(0).?);
}

test "orderBy: empty result set" {
    const allocator = std.testing.allocator;
    const path = "test_orderby_empty.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .where = &.{scan.Predicate.init(1, .gt, "99999")} });
    defer q.deinit();

    var result = try orderBy(allocator, &q, 1, false);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
}
