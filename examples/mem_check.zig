const std = @import("std");
const scanio = @import("scanio");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.debug.print("usage: mem_check <path>\n", .{});
        return;
    }

    var q = try scanio.Query.open(allocator, args[1], .{});
    defer q.deinit();

    var count: usize = 0;
    const t0 = std.time.nanoTimestamp();
    while (try q.next()) |_| count += 1;
    const t1 = std.time.nanoTimestamp();

    const secs = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
    std.debug.print("scanned {d} rows in {d:.3}s ({d:.1} rows/sec) via Query (format-aware)\n", .{ count, secs, @as(f64, @floatFromInt(count)) / secs });
}
