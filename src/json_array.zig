//! JSON array ([{...},{...},...]) support — converts to NDJSON text once,
//! then the existing NdjsonScanner pipeline runs unchanged. Same approach
//! zson (github.com/melihbirim/zson, MIT, same author) already uses for
//! this exact problem: vendored rather than re-derived, same reasoning as
//! json_parser.zig/json_simd.zig.
//!
//! Not streaming: the whole array is read and rewritten into one owned
//! NDJSON buffer up front. Consistent with how this project already
//! works, though — CSV and NDJSON both fully mmap their source file
//! already, so a JSON array file costs one additional allocation
//! proportional to file size, not a new class of memory behavior.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Format = enum { ndjson, json_array };

/// Detect whether data is NDJSON (objects separated by newlines) or a
/// JSON array ([...]) from the first non-whitespace byte.
pub fn detectFormat(data: []const u8) Format {
    for (data) |b| {
        switch (b) {
            ' ', '\t', '\n', '\r' => continue,
            '[' => return .json_array,
            else => break,
        }
    }
    return .ndjson;
}

/// Convert a JSON array ([{...},{...},...]) to NDJSON (one object per
/// line). Handles nested objects and strings correctly via a depth
/// counter and an in-string/escape tracker. Returns an owned slice;
/// caller frees with allocator.free().
pub fn jsonArrayToNdjson(data: []const u8, allocator: Allocator) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    var i: usize = 0;
    const len = data.len;

    while (i < len and data[i] != '[') : (i += 1) {}
    if (i >= len) return out.toOwnedSlice(allocator);
    i += 1;

    while (i < len) {
        while (i < len) : (i += 1) {
            const b = data[i];
            if (b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == ',') continue;
            break;
        }
        if (i >= len or data[i] == ']') break;
        if (data[i] != '{') {
            i += 1;
            continue;
        }

        const start = i;
        var depth: usize = 0;
        var in_string = false;
        while (i < len) : (i += 1) {
            const b = data[i];
            if (in_string) {
                if (b == '\\') {
                    i += 1;
                } else if (b == '"') {
                    in_string = false;
                }
            } else {
                switch (b) {
                    '"' => in_string = true,
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if (depth == 0) {
                            i += 1;
                            break;
                        }
                    },
                    else => {},
                }
            }
        }

        try out.appendSlice(allocator, data[start..i]);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

test "detectFormat: NDJSON vs JSON array" {
    try std.testing.expectEqual(Format.ndjson, detectFormat("{\"a\":1}\n"));
    try std.testing.expectEqual(Format.json_array, detectFormat("[{\"a\":1}]"));
    try std.testing.expectEqual(Format.json_array, detectFormat("  \n [{\"a\":1}]"));
}

test "jsonArrayToNdjson: basic conversion" {
    const allocator = std.testing.allocator;
    const input = "[{\"id\":1},{\"id\":2},{\"id\":3}]";
    const out = try jsonArrayToNdjson(input, allocator);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("{\"id\":1}\n{\"id\":2}\n{\"id\":3}\n", out);
}

test "jsonArrayToNdjson: nested objects and strings with braces/commas inside don't break splitting" {
    const allocator = std.testing.allocator;
    const input = "[{\"id\":1,\"note\":\"a, b {c}\"},{\"id\":2,\"meta\":{\"x\":1}}]";
    const out = try jsonArrayToNdjson(input, allocator);
    defer allocator.free(out);
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, out, "\n"), '\n');
    try std.testing.expectEqualStrings("{\"id\":1,\"note\":\"a, b {c}\"}", lines.next().?);
    try std.testing.expectEqualStrings("{\"id\":2,\"meta\":{\"x\":1}}", lines.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), lines.next());
}

test "jsonArrayToNdjson: empty array" {
    const allocator = std.testing.allocator;
    const out = try jsonArrayToNdjson("[]", allocator);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}
