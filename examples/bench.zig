//! Proves the "work not done" claims are real, not just narrative:
//! count() with no filter should be far faster than a row-by-row scan,
//! and limit() should return in time proportional to the limit, not the
//! file size.
const std = @import("std");
const scanio = @import("scanio");

fn timeIt(comptime label: []const u8, comptime f: anytype, args: anytype) !void {
    const t0 = std.time.nanoTimestamp();
    const result = try @call(.auto, f, args);
    const t1 = std.time.nanoTimestamp();
    const secs = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
    std.debug.print("{s}: {d:.4}s (result={any})\n", .{ label, secs, result });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.debug.print("usage: bench <path>\n", .{});
        return;
    }
    const path = args[1];

    // 1. Raw scan: touch every row.
    try timeIt("raw scan (every row)", struct {
        fn run(a: std.mem.Allocator, p: []const u8) !usize {
            var s = try scanio.Scanner.open(a, p);
            defer s.deinit();
            var n: usize = 0;
            while (try s.next()) |_| n += 1;
            return n;
        }
    }.run, .{ allocator, path });

    // 2. count() with no filter: should be far faster than #1 — no field
    //    splitting at all, just newline counting on already-mapped bytes.
    try timeIt("count() no filter (newline scan only)", struct {
        fn run(a: std.mem.Allocator, p: []const u8) !usize {
            var q = try scanio.Query.open(a, p, .{});
            defer q.deinit();
            return q.count();
        }
    }.run, .{ allocator, path });

    // 3. limit(10): should return almost instantly regardless of file size.
    try timeIt("limit(10)", struct {
        fn run(a: std.mem.Allocator, p: []const u8) !usize {
            var q = try scanio.Query.open(a, p, .{ .limit = 10 });
            defer q.deinit();
            var n: usize = 0;
            while (try q.next()) |_| n += 1;
            return n;
        }
    }.run, .{ allocator, path });

    // 4. first() with a rare-match predicate near the end of the file:
    //    should still stop the instant it finds the match, not scan twice.
    try timeIt("first() (filtered)", struct {
        fn run(a: std.mem.Allocator, p: []const u8) !usize {
            var q = try scanio.Query.open(a, p, .{ .where = &.{scanio.Predicate.init(0, .eq, "999999999")} });
            defer q.deinit();
            return if (try q.first() != null) @as(usize, 1) else 0;
        }
    }.run, .{ allocator, path });
}
