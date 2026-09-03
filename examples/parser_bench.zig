//! Isolated json_parser.zig throughput: parseObject() in a loop, no Query/
//! NdjsonScanner layer above it. Diagnostic tool that found the real M4
//! bottleneck (allocator choice, not the parsing algorithm — see
//! ndjson.zig's doc comment) — kept as a permanent way to re-isolate that
//! layer if this regresses, not a one-off script.
const std = @import("std");
const json_parser = @import("json_parser");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const file = try std.fs.cwd().openFile(args[1], .{});
    defer file.close();
    const size = (try file.stat()).size;
    const data = try std.posix.mmap(null, size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, file.handle, 0);
    defer std.posix.munmap(data);

    var count: usize = 0;
    var pos: usize = 0;
    const t0 = std.time.nanoTimestamp();
    while (pos < data.len) {
        const rel = std.mem.indexOfScalar(u8, data[pos..], '\n') orelse data.len - pos;
        const line = data[pos .. pos + rel];
        pos += rel + 1;
        if (line.len == 0) continue;
        var obj = try json_parser.parseObject(line, allocator);
        obj.deinit();
        count += 1;
    }
    const t1 = std.time.nanoTimestamp();
    const secs = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
    std.debug.print("parsed {d} objects in {d:.3}s ({d:.1} objects/sec)\n", .{ count, secs, @as(f64, @floatFromInt(count)) / secs });
}
