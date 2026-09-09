const std = @import("std");
const scanio = @import("scanio");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 4) {
        std.debug.print("usage: groupby_bench <path> <group_col> <agg_col> [single|parallel]\n", .{});
        return;
    }
    const path = args[1];
    const group_col_name = args[2];
    const agg_col_name = args[3];
    const only: ?[]const u8 = if (args.len > 4) args[4] else null;

    var probe = try scanio.Query.open(allocator, path, .{});
    const group_col = probe.columnIndex(group_col_name) orelse return error.UnknownColumn;
    const agg_col = probe.columnIndex(agg_col_name) orelse return error.UnknownColumn;
    probe.deinit();

    if (only == null or std.mem.eql(u8, only.?, "single")) {
        var q = try scanio.Query.open(allocator, path, .{});
        defer q.deinit();
        const t0 = std.time.nanoTimestamp();
        var result = try scanio.groupBy(allocator, &q, group_col, agg_col);
        const t1 = std.time.nanoTimestamp();
        defer result.deinit();
        const secs = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
        std.debug.print("single-threaded: groups={d} time={d:.4}s\n", .{ result.groups.count(), secs });
    }
    if (only == null or std.mem.eql(u8, only.?, "parallel")) {
        const t0 = std.time.nanoTimestamp();
        var result = try scanio.parallelGroupBy(allocator, path, ',', group_col, agg_col, 0);
        const t1 = std.time.nanoTimestamp();
        defer result.deinit();
        const secs = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
        std.debug.print("parallel:         groups={d} time={d:.4}s\n", .{ result.groups.count(), secs });
    }
}
