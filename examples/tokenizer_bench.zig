//! Isolated SIMD tokenizer throughput: findJsonStructure() alone, no
//! field parsing, no allocation. Diagnostic tool that ruled the
//! tokenizer OUT as the M4 slowdown's cause (15.5M lines/sec, matching
//! CSV's order of magnitude) — kept as a permanent way to re-check that
//! layer in isolation, not a one-off script.
const std = @import("std");
const json_simd = @import("json_simd");

pub fn main() !void {
    const line = "{\"id\":123456,\"name\":\"row123456\",\"amount\":45678}";
    var tokens: [4096]json_simd.Token = undefined;
    var total: usize = 0;

    const t0 = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < 500_000) : (i += 1) {
        total += json_simd.findJsonStructure(line, &tokens);
    }
    const t1 = std.time.nanoTimestamp();
    const secs = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
    std.debug.print("tokenized 500000 lines in {d:.3}s ({d:.1} lines/sec), total tokens={d}\n", .{ secs, @as(f64, 500_000) / secs, total });
}
