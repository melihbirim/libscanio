//! libscanio M7 (aggregates): count/sum/min/max/avg over a numeric
//! column, computed in one streaming pass — all five, not one pass per
//! function, since a second scan of the file costs exactly as much as
//! the first and this whole project's ethos is not doing work twice.
//! Non-numeric or missing values are skipped, not errors — matches SQL
//! aggregate semantics (ignore nulls), and lets an aggregate run over a
//! column that's numeric for most rows without failing on a stray blank.
const std = @import("std");
const scan = @import("root.zig");
const Query = scan.Query;

pub const AggResult = struct {
    count: usize = 0,
    sum: f64 = 0,
    min: ?f64 = null,
    max: ?f64 = null,

    pub fn avg(self: AggResult) ?f64 {
        if (self.count == 0) return null;
        return self.sum / @as(f64, @floatFromInt(self.count));
    }
};

pub fn aggregate(q: *Query, column: usize) !AggResult {
    var r = AggResult{};
    while (try q.next()) |row| {
        const field = row.get(column) orelse continue;
        // parseNumeric, not parseFloat: the latter accepts the literal
        // text "nan"/"inf", and one such cell used to poison sum, min
        // and max for the whole column (NaN compares false against
        // everything, so min/max could never move off it again).
        const v = scan.parseNumeric(field) orelse continue;
        r.count += 1;
        r.sum += v;
        if (r.min == null or v < r.min.?) r.min = v;
        if (r.max == null or v > r.max.?) r.max = v;
    }
    return r;
}

/// v1 scope, deliberate: single group column, single aggregate column,
/// count/sum/min/max/avg (the existing AggResult, reused rather than a
/// second result shape). No streaming bound on memory -- unlike every
/// other op in this library, RSS here tracks distinct group count, not
/// chunk size, because a hash-aggregation result set can't be assembled
/// any other way. Documented, not hidden: a GROUP BY over a near-unique
/// column (e.g. an id) will hold one entry per row, same as any other
/// GROUP BY engine. No parallelism yet.
pub const GroupByResult = struct {
    arena: std.heap.ArenaAllocator,
    groups: std.StringHashMap(AggResult),

    pub fn deinit(self: *GroupByResult) void {
        self.groups.deinit();
        self.arena.deinit();
    }
};

/// Single-pass hash aggregation: `q` should already carry any WHERE/
/// projection the caller wants applied before grouping (same composition
/// contract `aggregate()` already has — see its own "composes with WHERE"
/// test). `group_column`/`agg_column` are field indices into each row,
/// same indexing as `Row.get()`.
pub fn groupBy(allocator: std.mem.Allocator, q: *Query, group_column: usize, agg_column: usize) !GroupByResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var groups = std.StringHashMap(AggResult).init(allocator);
    errdefer groups.deinit();
    while (try q.next()) |row| {
        const key = row.get(group_column) orelse continue;
        const gop = try groups.getOrPut(key);
        if (!gop.found_existing) {
            // Row's field slices are only valid until the next next()
            // call (chunk buffer reuse, see root.zig's own doc comment)
            // -- the hash map key must outlive that, so it's duped once
            // per NEW group, not once per row. Arena-owned: freed all at
            // once via GroupByResult.deinit(), not per-key -- avoids
            // hand-rolled free-on-every-error-path bookkeeping entirely.
            gop.key_ptr.* = try arena.allocator().dupe(u8, key);
            gop.value_ptr.* = AggResult{};
        }
        const r = gop.value_ptr;
        if (row.get(agg_column)) |field| {
            if (scan.parseNumeric(field)) |v| {
                r.count += 1;
                r.sum += v;
                if (r.min == null or v < r.min.?) r.min = v;
                if (r.max == null or v > r.max.?) r.max = v;
            }
        }
    }
    return .{ .arena = arena, .groups = groups };
}

test "aggregate: sum/count/min/max/avg in one pass" {
    const allocator = std.testing.allocator;
    const path = "test_aggregate_basic.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n3,900\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    const r = try aggregate(&q, 1);
    try std.testing.expectEqual(@as(usize, 3), r.count);
    try std.testing.expectEqual(@as(f64, 2450), r.sum);
    try std.testing.expectEqual(@as(f64, 50), r.min.?);
    try std.testing.expectEqual(@as(f64, 1500), r.max.?);
    try std.testing.expectApproxEqAbs(@as(f64, 816.6666666), r.avg().?, 0.001);
}

test "aggregate: non-numeric values are skipped, not errors" {
    const allocator = std.testing.allocator;
    const path = "test_aggregate_mixed.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,\n3,900\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    const r = try aggregate(&q, 1);
    try std.testing.expectEqual(@as(usize, 2), r.count);
    try std.testing.expectEqual(@as(f64, 950), r.sum);
}

test "aggregate: composes with WHERE — aggregates only matching rows" {
    const allocator = std.testing.allocator;
    const path = "test_aggregate_filtered.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,city,amount\n1,Austin,50\n2,Austin,1500\n3,Denver,900\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .where = &.{scan.Predicate.init(1, .eq, "Austin")} });
    defer q.deinit();

    const r = try aggregate(&q, 2);
    try std.testing.expectEqual(@as(usize, 2), r.count);
    try std.testing.expectEqual(@as(f64, 1550), r.sum);
}

test "aggregate: empty result set (no rows match)" {
    const allocator = std.testing.allocator;
    const path = "test_aggregate_empty.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .where = &.{scan.Predicate.init(1, .gt, "999999")} });
    defer q.deinit();

    const r = try aggregate(&q, 1);
    try std.testing.expectEqual(@as(usize, 0), r.count);
    try std.testing.expectEqual(@as(?f64, null), r.avg());
}

test "aggregate: a literal 'nan'/'inf' cell is skipped, not parsed as a float" {
    // std.fmt.parseFloat accepts these as real NaN/Inf; once min/max held
    // a NaN, every later comparison was false and they never moved again,
    // and the sum stayed NaN for the rest of the column.
    const allocator = std.testing.allocator;
    const path = "test_aggregate_nan.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,nan\n2,50\n3,900\n4,inf\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    const r = try aggregate(&q, 1);
    try std.testing.expectEqual(@as(usize, 2), r.count);
    try std.testing.expectEqual(@as(f64, 950), r.sum);
    try std.testing.expectEqual(@as(f64, 50), r.min.?);
    try std.testing.expectEqual(@as(f64, 900), r.max.?);
}

test "groupBy: count/sum/min/max/avg per group, in one pass" {
    const allocator = std.testing.allocator;
    const path = "test_groupby_basic.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "city,amount\nAustin,50\nDenver,900\nAustin,1500\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    var result = try groupBy(allocator, &q, 0, 1);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.groups.count());
    const austin = result.groups.get("Austin").?;
    try std.testing.expectEqual(@as(usize, 2), austin.count);
    try std.testing.expectEqual(@as(f64, 1550), austin.sum);
    try std.testing.expectEqual(@as(f64, 50), austin.min.?);
    try std.testing.expectEqual(@as(f64, 1500), austin.max.?);
    try std.testing.expectApproxEqAbs(@as(f64, 775), austin.avg().?, 0.001);
    const denver = result.groups.get("Denver").?;
    try std.testing.expectEqual(@as(usize, 1), denver.count);
    try std.testing.expectEqual(@as(f64, 900), denver.sum);
}

test "groupBy: composes with WHERE — grouped over only matching rows" {
    const allocator = std.testing.allocator;
    const path = "test_groupby_filtered.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "city,status,amount\nAustin,open,50\nAustin,closed,1500\nDenver,open,900\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .where = &.{scan.Predicate.init(1, .eq, "open")} });
    defer q.deinit();

    var result = try groupBy(allocator, &q, 0, 2);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.groups.count());
    try std.testing.expectEqual(@as(f64, 50), result.groups.get("Austin").?.sum);
    try std.testing.expectEqual(@as(f64, 900), result.groups.get("Denver").?.sum);
}

test "groupBy: non-numeric agg values counted into the group but skipped from sum/min/max" {
    const allocator = std.testing.allocator;
    const path = "test_groupby_mixed.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "city,amount\nAustin,50\nAustin,oops\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    var result = try groupBy(allocator, &q, 0, 1);
    defer result.deinit();

    // Group exists (seen via the group column) even though one row's
    // agg value didn't parse -- same "skip, don't error" contract
    // aggregate() already has, just per-group instead of whole-column.
    const austin = result.groups.get("Austin").?;
    try std.testing.expectEqual(@as(usize, 1), austin.count);
    try std.testing.expectEqual(@as(f64, 50), austin.sum);
}

test "groupBy: empty result set (no rows match)" {
    const allocator = std.testing.allocator;
    const path = "test_groupby_empty.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "city,amount\nAustin,50\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .where = &.{scan.Predicate.init(1, .gt, "999999")} });
    defer q.deinit();

    var result = try groupBy(allocator, &q, 0, 1);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.groups.count());
}

test "groupBy: allocation failures release every duped key" {
    const allocationCase = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const path = "test_groupby_allocfail.csv";
            try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "city,amount\nAustin,50\nDenver,900\nAustin,1500\n" });
            defer std.fs.cwd().deleteFile(path) catch {};

            var q = try Query.open(allocator, path, .{});
            defer q.deinit();
            var result = try groupBy(allocator, &q, 0, 1);
            result.deinit();
        }
    }.run;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

test "groupBy: works over NDJSON too, not just CSV -- composes over any Query" {
    // groupBy() is format-agnostic by construction: it only calls
    // q.next()/row.get(), same as aggregate() above, and Query already
    // handles CSV/NDJSON/JSON-array uniformly. Unlike parallelGroupBy()
    // (CSV-only, v1 scope, see its own doc comment), this path was never
    // CSV-specific -- this test exists to prove that, not just assert it.
    const allocator = std.testing.allocator;
    const path = "test_groupby_ndjson.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data =
        \\{"city":"Austin","amount":50}
        \\{"city":"Denver","amount":900}
        \\{"city":"Austin","amount":1500}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    var result = try groupBy(allocator, &q, 0, 1);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.groups.count());
    try std.testing.expectEqual(@as(f64, 1550), result.groups.get("Austin").?.sum);
    try std.testing.expectEqual(@as(f64, 900), result.groups.get("Denver").?.sum);
}
