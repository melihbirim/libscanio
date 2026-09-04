const std = @import("std");
const scanio = @import("scanio");

/// Exercises Query.count()'s no-WHERE fast path specifically (newline/
/// object counting, never splits a field) — NOT the same thing
/// mem_check.zig measures (a full next()-loop, splitting every field of
/// every row). The two answer different questions: this one is the fair
/// comparison to a tool like `xan count` or `duckdb SELECT count(*)`,
/// which also don't parse fields for a bare count.
pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.debug.print("usage: count_bench <path>\n", .{});
        return;
    }

    var q = try scanio.Query.open(allocator, args[1], .{});
    defer q.deinit();

    const t0 = std.time.nanoTimestamp();
    const count = try q.count();
    const t1 = std.time.nanoTimestamp();
    const secs = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
    std.debug.print("count={d} time={d:.3}s ({d:.1} rows/sec)\n", .{ count, secs, @as(f64, @floatFromInt(count)) / secs });
}
