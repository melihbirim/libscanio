const std = @import("std");
const scanio = @import("scanio");

pub fn main() !void {
    // c_allocator, not GeneralPurposeAllocator: GPA's per-allocation
    // tracking overhead is large enough to be the dominant cost for
    // NDJSON's many-small-allocations pattern — see ndjson.zig's doc
    // comment. Benchmark with the allocator you'd actually ship, or the
    // number you get isn't the number a real caller sees.
    const allocator = std.heap.c_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.debug.print("usage: scan_file <path>\n", .{});
        return;
    }

    var scanner = try scanio.Scanner.open(allocator, args[1]);
    defer scanner.deinit();

    var count: usize = 0;
    const t0 = std.time.nanoTimestamp();
    while (try scanner.next()) |_| count += 1;
    const t1 = std.time.nanoTimestamp();

    const secs = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
    std.debug.print("scanned {d} rows in {d:.3}s ({d:.1} rows/sec)\n", .{ count, secs, @as(f64, @floatFromInt(count)) / secs });
}
