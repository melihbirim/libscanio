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
