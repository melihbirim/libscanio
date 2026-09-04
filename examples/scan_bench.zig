const std = @import("std");
const scanio = @import("scanio");

/// Single-threaded, WHERE-filtered, MATERIALIZED scan — same job as the
/// Python/Node bindings' scan_array()/scanArray() (every matching row's
/// fields duplicated so they survive past the reused per-row scan
/// buffer). Built for the N-way concurrency experiment (ROADMAP.md),
/// then rewritten after that experiment surfaced a real, fixable memory
/// problem: the first version used a growing ArenaAllocator with one
/// small allocation per FIELD (millions of tiny allocations for a
/// million-row result) — real waste from the arena's doubling growth
/// strategy plus per-allocation overhead, not the theoretical minimum
/// cost of just holding the matched bytes.
///
/// Two-pass, exact-sized instead: pass 1 scans once counting matches AND
/// summing every matching field's byte length (the file is scanned
/// twice, but that's a fixed multiplier on TIME, and this bench is about
/// MEMORY); pass 2 allocates exactly two buffers — one flat `[]u8` for
/// every matched field's bytes back-to-back, one flat array of field
/// references indexed by `row*n_columns + col` instead of each row
/// owning a separate small slice array — then fills both in a single
/// pass with zero further allocation. Two big allocations total, not
/// (matches * columns) small ones.
///
/// That alone barely moved memory (286MB, near-identical to the
/// original arena version) — measured, not assumed to have worked:
/// `n_matches * n_columns * 16 bytes` (a `[]const u8` slice is
/// ptr(8)+len(8) on 64-bit) alone was 190MB of that 286MB on the real
/// 1.24M-row fixture this was benchmarked against. The dominant cost
/// was never allocator overhead/fragmentation — it's the fixed 16-byte
/// cost of addressing each field at all, paid once per field regardless
/// of how short the actual string is (most fields here are a handful of
/// bytes). Fixed by shrinking `FieldRef` to `{offset: u32, len: u32}`
/// (8 bytes) instead of a full slice — halves that 190MB to ~95MB. u32
/// offsets are safe here since `data_buf` (the single flat byte buffer
/// every field's bytes live in) is bounded by `total_bytes`, nowhere
/// near 4GB for any file this bench is meant to run against.
const FieldRef = struct { offset: u32, len: u32 };
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
    const n_columns = probe.header().len;
    probe.deinit();

    const t0 = std.time.nanoTimestamp();

    // Pass 1: count matches and total bytes needed, no allocation.
    var n_matches: usize = 0;
    var total_bytes: usize = 0;
    {
        var q1 = try scanio.Query.open(allocator, path, .{
            .where = &.{scanio.Predicate.init(col_idx, .eq, value)},
        });
        defer q1.deinit();
        while (try q1.next()) |row| {
            n_matches += 1;
            for (row.fields) |f| total_bytes += f.len;
        }
    }

    // Pass 2: exactly two allocations, fill in one pass, no further growth.
    const data_buf = try allocator.alloc(u8, total_bytes);
    defer allocator.free(data_buf);
    const fields_flat = try allocator.alloc(FieldRef, n_matches * n_columns);
    defer allocator.free(fields_flat);

    var data_pos: u32 = 0;
    var row_idx: usize = 0;
    {
        var q2 = try scanio.Query.open(allocator, path, .{
            .where = &.{scanio.Predicate.init(col_idx, .eq, value)},
        });
        defer q2.deinit();
        while (try q2.next()) |row| {
            for (row.fields, 0..) |f, col| {
                @memcpy(data_buf[data_pos .. data_pos + f.len], f);
                fields_flat[row_idx * n_columns + col] = .{ .offset = data_pos, .len = @intCast(f.len) };
                data_pos += @intCast(f.len);
            }
            row_idx += 1;
        }
    }

    const t1 = std.time.nanoTimestamp();
    const secs = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
    std.debug.print("matches={d} time={d:.3}s\n", .{ n_matches, secs });
}
