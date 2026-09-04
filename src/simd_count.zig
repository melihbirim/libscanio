//! Vectorized single-byte counting — shared by every "how many records
//! are in this file" fast path (Scanner.countRemaining() in root.zig,
//! NdjsonScanner.countRemaining()'s line-delimited branch in ndjson.zig,
//! parallel.zig's countRange()). Split out as its own file since the
//! naive scalar loop it replaced was NOT format-specific (pure
//! byte-counting, nothing CSV/JSON about it) and neither is the fix.
//!
//! Real, measured motivation: the scalar loop this replaced
//! (`for (chunk) |c| if (c == needle) count += 1`) is the same class of
//! missed-SIMD issue json_simd.zig's tokenizer had before its own
//! bitmask fix (see ROADMAP.md's M4 entry) — except simpler to fix here,
//! since a pure COUNT (not positions) can go straight to a per-chunk
//! popcount/reduce instead of needing json_simd.zig's bitmask+@ctz walk.
//! Benchmarked against xan (Rust, github.com/medialab/xan, built on
//! heavily SIMD-optimized byte search) on a real 10.46GB/130M-row file:
//! xan counted rows in 6.00s; the scalar loop this replaced took 13.41s
//! for the identical operation on the identical file — over 2x slower
//! for work that's pure byte comparison.
const std = @import("std");

/// Count of `needle` occurrences in `data`. Uses the widest vector this
/// target reasonably supports (std.simd.suggestVectorLength, same
/// signal Zig's own stdlib SIMD paths use — see std.mem.indexOfScalarPos)
/// rather than a fixed width, so this scales with the actual CPU instead
/// of guessing.
pub fn countByte(data: []const u8, needle: u8) usize {
    const chunk_size = std.simd.suggestVectorLength(u8) orelse 16;
    return countByteN(chunk_size, data, needle);
}

fn countByteN(comptime chunk_size: usize, data: []const u8, needle: u8) usize {
    const Vec = @Vector(chunk_size, u8);
    // Match vector is u32, not u8: @reduce(.Add, ...) returns the same
    // element type it's given, and a u8 accumulator would silently wrap
    // if chunk_size ever exceeded 255 on some future wide-SIMD target
    // (AVX-512 alone can already reach 64 lanes for u8; not a risk
    // today, but a u32 lane costs nothing extra here and removes the
    // question entirely).
    const MatchVec = @Vector(chunk_size, u32);
    const needle_v: Vec = @splat(needle);
    const ones: MatchVec = @splat(1);
    const zeros: MatchVec = @splat(0);

    var i: usize = 0;
    var total: usize = 0;
    while (i + chunk_size <= data.len) : (i += chunk_size) {
        const chunk: Vec = data[i..][0..chunk_size].*;
        const eq = chunk == needle_v;
        const matched: MatchVec = @select(u32, eq, ones, zeros);
        total += @reduce(.Add, matched);
    }
    while (i < data.len) : (i += 1) {
        if (data[i] == needle) total += 1;
    }
    return total;
}

test "countByte: matches a scalar reference count on assorted sizes/densities" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const sizes = [_]usize{ 0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 1000, 100_000 };
    for (sizes) |size| {
        const buf = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(buf);
        for (buf) |*b| b.* = if (random.uintLessThan(u8, 10) == 0) '\n' else random.uintLessThan(u8, 255);

        var expected: usize = 0;
        for (buf) |c| {
            if (c == '\n') expected += 1;
        }
        try std.testing.expectEqual(expected, countByte(buf, '\n'));
    }
}

test "countByte: all-matching and none-matching" {
    const all_nl = "\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n";
    try std.testing.expectEqual(@as(usize, all_nl.len), countByte(all_nl, '\n'));

    const none = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";
    try std.testing.expectEqual(@as(usize, 0), countByte(none, '\n'));
}
