const std = @import("std");

/// SIMD-accelerated JSON parsing utilities
/// Inspired by simdjson and proven patterns from sieswi
/// Token types for JSON structural characters
pub const TokenType = enum {
    open_brace, // {
    close_brace, // }
    open_bracket, // [
    close_bracket, // ]
    quote, // "
    colon, // :
    comma, // ,
    unknown,
};

pub const Token = struct {
    type: TokenType,
    pos: usize,
};

/// Generic SIMD structural-character scanner.
///
/// `chunk_size` controls how many bytes are processed per SIMD iteration.
/// On aarch64 the native NEON register is 16 bytes; larger values make the
/// compiler emit multiple NEON operations per loop iteration, reducing
/// branch / loop overhead at the cost of more register pressure.
///
/// Practical sweet-spots to try: 16, 32, 64, 128.
///
/// ## Algorithm
/// Stage 1 – compare `chunk_size` bytes against each of the 7 structural chars.
/// Stage 2 – `@reduce(.Or, is_any)` skips the chunk entirely when empty.
///           Per non-empty lane: `is_any[j]` guard before 7-way type dispatch.
pub fn findJsonStructureN(comptime chunk_size: usize, data: []const u8, tokens: []Token) usize {
    var count: usize = 0;

    const Vec = @Vector(chunk_size, u8);
    const open_brace: Vec = @splat('{');
    const close_brace: Vec = @splat('}');
    const open_bracket: Vec = @splat('[');
    const close_bracket: Vec = @splat(']');
    const quote: Vec = @splat('"');
    const colon: Vec = @splat(':');
    const comma: Vec = @splat(',');

    var i: usize = 0;
    while (i + chunk_size <= data.len and count < tokens.len) : (i += chunk_size) {
        const chunk: Vec = data[i..][0..chunk_size].*;

        const is_open_brace = chunk == open_brace;
        const is_close_brace = chunk == close_brace;
        const is_open_bracket = chunk == open_bracket;
        const is_close_bracket = chunk == close_bracket;
        const is_quote = chunk == quote;
        const is_colon = chunk == colon;
        const is_comma = chunk == comma;

        const is_any = is_open_brace | is_close_brace | is_open_bracket |
            is_close_bracket | is_quote | is_colon | is_comma;

        if (!@reduce(.Or, is_any)) continue;

        var j: usize = 0;
        while (j < chunk_size and count < tokens.len) : (j += 1) {
            if (!is_any[j]) continue;
            const tok_type: TokenType =
                if (is_open_brace[j]) .open_brace else if (is_close_brace[j]) .close_brace else if (is_open_bracket[j]) .open_bracket else if (is_close_bracket[j]) .close_bracket else if (is_quote[j]) .quote else if (is_colon[j]) .colon else .comma;
            tokens[count] = Token{ .type = tok_type, .pos = i + j };
            count += 1;
        }
    }

    // Handle remaining bytes (scalar fallback)
    while (i < data.len and count < tokens.len) : (i += 1) {
        const token_type: TokenType = switch (data[i]) {
            '{' => .open_brace,
            '}' => .close_brace,
            '[' => .open_bracket,
            ']' => .close_bracket,
            '"' => .quote,
            ':' => .colon,
            ',' => .comma,
            else => continue,
        };

        tokens[count] = Token{ .type = token_type, .pos = i };
        count += 1;
    }

    return count;
}

/// Find JSON structural characters — default 16-byte chunk (one NEON register).
/// Call `findJsonStructureN(32, ...)` etc. to experiment with wider chunks.
pub fn findJsonStructure(data: []const u8, tokens: []Token) usize {
    return findJsonStructureN(16, data, tokens);
}

/// Fast SIMD-optimized newline search (same as sieswi)
/// For splitting NDJSON into lines
pub inline fn findNewline(haystack: []const u8, start: usize) ?usize {
    if (start >= haystack.len) return null;

    const data = haystack[start..];

    // For small searches, use standard library
    if (data.len < 64) {
        if (std.mem.indexOfScalar(u8, data, '\n')) |pos| {
            return start + pos;
        }
        return null;
    }

    // For larger searches, std.mem.indexOfScalar may use SIMD internally
    if (std.mem.indexOfScalar(u8, data, '\n')) |pos| {
        return start + pos;
    }

    return null;
}

/// Fast string equality check using SIMD when available
/// Reused from sieswi - works great for JSON key comparison
pub inline fn stringsEqualFast(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.ptr == b.ptr) return true;

    // For short strings, use direct comparison
    if (a.len < 16) {
        return std.mem.eql(u8, a, b);
    }

    // For longer strings, std.mem.eql may use SIMD internally
    return std.mem.eql(u8, a, b);
}

/// Parse integer fast (for numeric JSON values)
/// Optimized version from sieswi
pub inline fn parseIntFast(str: []const u8) !i64 {
    // Skip leading whitespace
    var i: usize = 0;
    while (i < str.len and std.ascii.isWhitespace(str[i])) : (i += 1) {}

    if (i >= str.len) return error.InvalidInput;

    // Check for sign
    var negative = false;
    if (str[i] == '-') {
        negative = true;
        i += 1;
    } else if (str[i] == '+') {
        i += 1;
    }

    if (i >= str.len) return error.InvalidInput;

    // Parse digits - compiler can vectorize this loop
    var result: i64 = 0;
    while (i < str.len) : (i += 1) {
        const c = str[i];
        if (c < '0' or c > '9') break;
        result = result * 10 + (c - '0');
    }

    return if (negative) -result else result;
}

/// Parse float fast (for numeric JSON values)
pub inline fn parseFloatFast(str: []const u8) !f64 {
    return try std.fmt.parseFloat(f64, str);
}

test "SIMD JSON tokenization" {
    const json = "{\"name\":\"Alice\",\"age\":30}";
    var tokens: [100]Token = undefined;

    const count = findJsonStructure(json, &tokens);

    // Should find: { " " : " " , " " : } = 11 structural chars (7 unique + 4 quotes)
    try std.testing.expect(count > 0);
    try std.testing.expectEqual(TokenType.open_brace, tokens[0].type);
    try std.testing.expectEqual(@as(usize, 0), tokens[0].pos);
}

test "newline search" {
    const data = "line1\nline2\nline3\n";

    const pos1 = findNewline(data, 0);
    try std.testing.expectEqual(@as(usize, 5), pos1.?);

    const pos2 = findNewline(data, 6);
    try std.testing.expectEqual(@as(usize, 11), pos2.?);
}

test "fast integer parsing" {
    try std.testing.expectEqual(@as(i64, 42), try parseIntFast("42"));
    try std.testing.expectEqual(@as(i64, -123), try parseIntFast("-123"));
    try std.testing.expectEqual(@as(i64, 0), try parseIntFast("0"));
}
