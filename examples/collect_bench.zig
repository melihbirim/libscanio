const std = @import("std");
const scanio = @import("scanio");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 5) {
        std.debug.print("usage: collect_bench <path> <col1> <col2> <where_col> <where_val>\n", .{});
        return;
    }
    const path = args[1];
    const col1_name = args[2];
    const col2_name = args[3];
    const where_col_name = args[4];
    const where_val = args[5];

    var probe = try scanio.Query.open(allocator, path, .{});
    const col1 = probe.columnIndex(col1_name) orelse return error.UnknownColumn;
    const col2 = probe.columnIndex(col2_name) orelse return error.UnknownColumn;
    const where_col = probe.columnIndex(where_col_name) orelse return error.UnknownColumn;
    probe.deinit();

    const max_col = @max(col1, @max(col2, where_col));
    var q = try scanio.Query.open(allocator, path, .{
        .columns = &.{ col1, col2 },
        .where = &.{scanio.Predicate.init(where_col, .eq, where_val)},
        .stop_after_column = max_col,
    });
    defer q.deinit();

    // Same shape as scan_array()'s C-side collect: NUL-separated,
    // row-major, in one growable buffer -- real materialization work,
    // not just counting.
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    var count: usize = 0;
    const t0 = std.time.nanoTimestamp();
    while (try q.next()) |row| {
        for (row.fields) |field| {
            try buf.appendSlice(allocator, field);
            try buf.append(allocator, 0);
        }
        count += 1;
    }
    const t1 = std.time.nanoTimestamp();
    const secs = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
    std.debug.print("matches={d} time={d:.3}s bytes_collected={d}\n", .{ count, secs, buf.items.len });
}
