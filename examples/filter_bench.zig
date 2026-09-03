const std = @import("std");
const scanio = @import("scanio");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 4) {
        std.debug.print("usage: filter_bench <path> <column> <value>\n", .{});
        return;
    }
    const path = args[1];
    const column = args[2];
    const value = args[3];

    var probe = try scanio.Query.open(allocator, path, .{});
    const col_idx = probe.columnIndex(column) orelse return error.UnknownColumn;
    probe.deinit();

    var q = try scanio.Query.open(allocator, path, .{
        .where = &.{scanio.Predicate.init(col_idx, .eq, value)},
    });
    defer q.deinit();

    var count: usize = 0;
    const t0 = std.time.nanoTimestamp();
    while (try q.next()) |_| count += 1;
    const t1 = std.time.nanoTimestamp();
    const secs = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
    std.debug.print("matches={d} time={d:.3}s\n", .{ count, secs });
}
