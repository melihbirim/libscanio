const std = @import("std");
const scanio = @import("scanio");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.debug.print("usage: parallel_bench <path> [column value]\n", .{});
        return;
    }
    const path = args[1];

    const t0 = std.time.nanoTimestamp();
    if (args.len >= 4) {
        const column = args[2];
        const value = args[3];
        var probe = try scanio.Query.open(allocator, path, .{});
        const col_idx = probe.columnIndex(column) orelse return error.UnknownColumn;
        probe.deinit();
        const predicates = [_]scanio.Predicate{scanio.Predicate.init(col_idx, .eq, value)};
        const count = try scanio.parallelCountRowsWhere(allocator, path, ',', &predicates, 0);
        const t1 = std.time.nanoTimestamp();
        std.debug.print("matches={d} time={d:.3}s\n", .{ count, @as(f64, @floatFromInt(t1 - t0)) / 1e9 });
    } else {
        const count = try scanio.parallelCountRows(allocator, path, 0);
        const t1 = std.time.nanoTimestamp();
        std.debug.print("count={d} time={d:.3}s\n", .{ count, @as(f64, @floatFromInt(t1 - t0)) / 1e9 });
    }
}
