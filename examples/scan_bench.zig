const std = @import("std");
const scanio = @import("scanio");

/// Single-threaded, WHERE-filtered, MATERIALIZED scan — same memory
/// shape as the Python/Node bindings' scan_array()/scanArray() (every
/// matching row's fields duplicated so they survive past the reused
/// per-row scan buffer), not the bounded-memory streaming scan()/count()
/// path. Exists specifically for the N-way concurrency experiment
/// (ROADMAP.md): "return matching rows" is what an agent's scan_array()
/// tool call actually does, not just a count.
pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 4) {
        std.debug.print("usage: scan_bench <path> <column> <value>\n", .{});
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

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var rows: std.ArrayListUnmanaged([][]const u8) = .{};

    const t0 = std.time.nanoTimestamp();
    while (try q.next()) |row| {
        const fields = try aa.alloc([]const u8, row.fields.len);
        for (row.fields, 0..) |f, i| fields[i] = try aa.dupe(u8, f);
        try rows.append(aa, fields);
    }
    const t1 = std.time.nanoTimestamp();
    const secs = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
    std.debug.print("matches={d} time={d:.3}s\n", .{ rows.items.len, secs });
}
