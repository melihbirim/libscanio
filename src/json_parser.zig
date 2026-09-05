const std = @import("std");
const simd = @import("json_simd.zig");
const Allocator = std.mem.Allocator;

/// JSON value types (union for different types)
pub const JsonValue = union(enum) {
    null_value,
    bool_value: bool,
    number: []const u8, // Zero-copy slice! We keep it as string and parse on-demand
    string: []const u8, // Zero-copy slice into original data
    object: JsonObject,
    array: []JsonValue,

    pub fn format(
        self: JsonValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .null_value => try writer.writeAll("null"),
            .bool_value => |b| try writer.writeAll(if (b) "true" else "false"),
            .number => |n| try writer.writeAll(n),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .object => try writer.writeAll("[object]"),
            .array => try writer.writeAll("[array]"),
        }
    }
};

/// JSON object - collection of key-value pairs
/// Zero-copy: keys and simple values are slices into original data
pub const JsonObject = struct {
    fields: []Field,
    allocator: Allocator,
    owned_strings: ?[][]u8 = null,

    pub const Field = struct {
        key: []const u8, // Zero-copy slice
        value: JsonValue,
        key_owned: bool = false,
    };

    /// Get field value by key (O(n) for MVP, can optimize later with HashMap)
    pub fn get(self: JsonObject, key: []const u8) ?JsonValue {
        for (self.fields) |field| {
            if (simd.stringsEqualFast(field.key, key)) {
                return field.value;
            }
        }
        return null;
    }

    pub fn deinit(self: *JsonObject) void {
        // Free nested objects and arrays recursively
        for (self.fields) |*field| {
            if (field.key_owned) self.allocator.free(field.key);
            switch (field.value) {
                .string => |s| {
                    if (self.ownsString(s)) self.allocator.free(s);
                },
                .object => |*nested| {
                    var obj = nested.*;
                    obj.deinit();
                },
                .array => |arr| {
                    for (arr) |*item| {
                        switch (item.*) {
                            .string => |s| if (self.ownsString(s)) self.allocator.free(s),
                            .object => {
                                var obj = item.object;
                                obj.deinit();
                            },
                            else => {},
                        }
                    }
                    self.allocator.free(arr);
                },
                else => {},
            }
        }
        if (self.owned_strings) |owned| self.allocator.free(owned);
        self.allocator.free(self.fields);
    }

    inline fn ownsString(self: JsonObject, s: []const u8) bool {
        const owned = self.owned_strings orelse return false;
        for (owned) |owned_string| {
            if (owned_string.ptr == s.ptr and owned_string.len == s.len) return true;
        }
        return false;
    }
};

/// Parse a single JSON object from a line (NDJSON)
/// Returns zero-copy slices into the original line data
pub fn parseObject(line: []const u8, allocator: Allocator) ParseError!JsonObject {
    // Tokenize using SIMD
    var tokens: [4096]simd.Token = undefined;
    const token_count = simd.findJsonStructure(line, &tokens);

    if (token_count == 0 or tokens[0].type != .open_brace) {
        return error.InvalidJSON;
    }

    // Parse fields
    var fields = std.ArrayList(JsonObject.Field){};
    var owned_strings = std.ArrayList([]u8){};
    errdefer {
        for (fields.items) |*field| {
            if (field.key_owned) allocator.free(field.key);
        }
        fields.deinit(allocator);
        for (owned_strings.items) |s| allocator.free(s);
        owned_strings.deinit(allocator);
    }

    var i: usize = 1; // Skip opening {
    while (i < token_count) {
        const token = tokens[i];

        // Check for closing brace
        if (token.type == .close_brace) {
            break;
        }

        // Expect: " key " : value
        if (token.type != .quote) {
            // Skip commas
            if (token.type == .comma) {
                i += 1;
                continue;
            }
            return error.ExpectedQuote;
        }

        const key_start = token.pos + 1;
        const key_end = findStringEndFromTokens(line, tokens[0..token_count], i + 1, key_start) orelse return error.MalformedKey;
        const raw_key = line[key_start..key_end];
        const key_has_escape = hasJsonEscape(raw_key);
        const key = if (key_has_escape) try decodeOwnedJsonString(raw_key, allocator) else raw_key;
        advanceTokenIndex(tokens[0..token_count], &i, key_end + 1);

        // Expect colon
        if (i >= token_count or tokens[i].type != .colon) {
            return error.ExpectedColon;
        }
        const colon_pos = tokens[i].pos;
        i += 1; // Skip colon

        // Parse value - pass the colon position for literal extraction
        const value = try parseValueAfterColon(line, tokens[0..token_count], &i, colon_pos, allocator, &owned_strings);

        try fields.append(allocator, JsonObject.Field{
            .key = key,
            .value = value,
            .key_owned = key_has_escape,
        });
    }

    return JsonObject{
        .fields = try fields.toOwnedSlice(allocator),
        .allocator = allocator,
        .owned_strings = if (owned_strings.items.len > 0)
            try owned_strings.toOwnedSlice(allocator)
        else blk: {
            owned_strings.deinit(allocator);
            break :blk null;
        },
    };
}

/// Same as parseObject, but the fields/owned_strings arrays are supplied
/// by the caller instead of allocated fresh — cleared and refilled, not
/// reallocated, on every call. Added for libscanio's NdjsonScanner: at
/// 500K rows/file, parseObject()'s own internal `std.ArrayList(){}` +
/// `.toOwnedSlice()` per call was still a malloc/free pair per row even
/// after the caller switched to an arena allocator, since the array
/// itself was still being freshly requested and detached every time.
/// Two allocators, not one: `list_allocator` grows `fields`/
/// `owned_strings` themselves and should be a real, persistent allocator
/// (grows once, then stays put across the whole file) — `value_allocator`
/// is for the actual decoded-string bytes and is expected to be a
/// per-row arena the caller resets between calls, since those bytes
/// genuinely are only needed until the next row.
pub fn parseObjectReuse(
    line: []const u8,
    list_allocator: Allocator,
    value_allocator: Allocator,
    fields: *std.ArrayList(JsonObject.Field),
    owned_strings: *std.ArrayList([]u8),
) ParseError!JsonObject {
    fields.clearRetainingCapacity();
    owned_strings.clearRetainingCapacity();

    var tokens: [4096]simd.Token = undefined;
    const token_count = simd.findJsonStructure(line, &tokens);

    if (token_count == 0 or tokens[0].type != .open_brace) {
        return error.InvalidJSON;
    }

    var i: usize = 1; // Skip opening {
    while (i < token_count) {
        const token = tokens[i];

        if (token.type == .close_brace) {
            break;
        }

        if (token.type != .quote) {
            if (token.type == .comma) {
                i += 1;
                continue;
            }
            return error.ExpectedQuote;
        }

        const key_start = token.pos + 1;
        const key_end = findStringEndFromTokens(line, tokens[0..token_count], i + 1, key_start) orelse return error.MalformedKey;
        const raw_key = line[key_start..key_end];
        const key_has_escape = hasJsonEscape(raw_key);
        const key = if (key_has_escape) try decodeOwnedJsonString(raw_key, value_allocator) else raw_key;
        advanceTokenIndex(tokens[0..token_count], &i, key_end + 1);

        if (i >= token_count or tokens[i].type != .colon) {
            return error.ExpectedColon;
        }
        const colon_pos = tokens[i].pos;
        i += 1; // Skip colon

        const value = try parseValueAfterColon(line, tokens[0..token_count], &i, colon_pos, value_allocator, owned_strings);

        try fields.append(list_allocator, JsonObject.Field{
            .key = key,
            .value = value,
            .key_owned = key_has_escape,
        });
    }

    // fields.items / owned_strings.items are views into caller-owned,
    // caller-persisted buffers — not detached via toOwnedSlice(), and not
    // this JsonObject's to free. The caller must not call .deinit() on
    // the result; clearRetainingCapacity() on the next call (or the
    // caller's own cleanup) is what reclaims this memory.
    return JsonObject{
        .fields = fields.items,
        .allocator = list_allocator,
        .owned_strings = null,
    };
}

pub const ParseError = error{
    InvalidJSON,
    ExpectedQuote,
    MalformedKey,
    ExpectedColon,
    UnexpectedEnd,
    MalformedString,
    ArraysNotSupported,
    UnexpectedToken,
    InvalidInput,
    InvalidCharacter,
    NotANumber,
    NotAString,
    NotABoolean,
    InvalidEscape,
    InvalidUnicodeEscape,
    OutOfMemory,
};

/// Parse a JSON value that comes after a colon
/// i points to the token after the colon (may be quote, comma, or close brace)
/// colon_pos is the position of the colon in the source text
fn parseValueAfterColon(
    line: []const u8,
    tokens: []simd.Token,
    i: *usize,
    colon_pos: usize,
    allocator: Allocator,
    owned_strings: *std.ArrayList([]u8),
) ParseError!JsonValue {
    if (i.* >= tokens.len) return error.UnexpectedEnd;

    const next_token = tokens[i.*];

    switch (next_token.type) {
        .quote => {
            const start = next_token.pos + 1;
            const end = findStringEndFromTokens(line, tokens, i.* + 1, start) orelse return error.MalformedString;
            const raw = line[start..end];
            const has_escape = hasJsonEscape(raw);
            const value = if (has_escape) try decodeOwnedJsonString(raw, allocator) else raw;
            if (has_escape) try owned_strings.append(allocator, @constCast(value));
            advanceTokenIndex(tokens, i, end + 1);

            return JsonValue{ .string = value };
        },
        .open_brace => {
            // Nested object - parse it recursively
            // Find the matching close brace
            var brace_depth: i32 = 1;
            var end_pos = next_token.pos + 1;

            while (end_pos < line.len and brace_depth > 0) : (end_pos += 1) {
                if (line[end_pos] == '{') brace_depth += 1;
                if (line[end_pos] == '}') brace_depth -= 1;
            }

            const nested_json = line[next_token.pos..end_pos];
            const nested_obj = try parseObject(nested_json, allocator);

            // Skip tokens until we pass the close brace
            while (i.* < tokens.len and tokens[i.*].pos < end_pos) {
                i.* += 1;
            }

            return JsonValue{ .object = nested_obj };
        },
        .open_bracket => {
            // Array - parse elements recursively
            var array_items = std.ArrayList(JsonValue){};
            errdefer {
                for (array_items.items) |*item| {
                    if (item.* == .object) {
                        var obj = item.object;
                        obj.deinit();
                    }
                }
                array_items.deinit(allocator);
            }

            // Find the array content between [ and ]
            const array_start = next_token.pos;
            var bracket_depth: i32 = 1;
            var end_pos = array_start + 1;

            while (end_pos < line.len and bracket_depth > 0) : (end_pos += 1) {
                if (line[end_pos] == '[') bracket_depth += 1;
                if (line[end_pos] == ']') bracket_depth -= 1;
            }

            const array_content = line[array_start + 1 .. end_pos - 1];

            // Parse each element: strings, numbers, booleans, nulls, objects
            if (std.mem.trim(u8, array_content, &std.ascii.whitespace).len > 0) {
                var elem_start: usize = 0;
                var depth: i32 = 0;
                var in_str = false;

                for (array_content, 0..) |ch, idx| {
                    if (ch == '"' and (idx == 0 or array_content[idx - 1] != '\\')) {
                        in_str = !in_str;
                    }
                    if (in_str) continue;
                    if (ch == '{' or ch == '[') depth += 1;
                    if (ch == '}' or ch == ']') depth -= 1;

                    const is_sep = ch == ',' and depth == 0;
                    const is_last = idx == array_content.len - 1;

                    if (is_sep or is_last) {
                        const end = if (is_sep) idx else idx + 1;
                        const elem = std.mem.trim(u8, array_content[elem_start..end], " \t\r\n");
                        if (elem.len > 0) {
                            const val = try parseArrayElement(elem, allocator, owned_strings);
                            try array_items.append(allocator, val);
                        }
                        elem_start = idx + 1;
                    }
                }
            }

            // Skip tokens until we pass the close bracket
            while (i.* < tokens.len and tokens[i.*].pos < end_pos) {
                i.* += 1;
            }

            return JsonValue{ .array = try array_items.toOwnedSlice(allocator) };
        },
        .comma, .close_brace => {
            // The value is a literal between the colon and this token
            // Extract it from the source text
            var value_start = colon_pos + 1;
            while (value_start < next_token.pos and std.ascii.isWhitespace(line[value_start])) {
                value_start += 1;
            }

            const value_end = next_token.pos;
            const literal = std.mem.trim(u8, line[value_start..value_end], &std.ascii.whitespace);

            // Determine type
            if (std.mem.eql(u8, literal, "null")) {
                return JsonValue{ .null_value = {} };
            } else if (std.mem.eql(u8, literal, "true")) {
                return JsonValue{ .bool_value = true };
            } else if (std.mem.eql(u8, literal, "false")) {
                return JsonValue{ .bool_value = false };
            } else {
                // Assume number (keep as zero-copy string, parse on-demand)
                return JsonValue{ .number = literal };
            }
        },
        else => {
            return error.UnexpectedToken;
        },
    }
}

/// Parse a single element inside a JSON array (string, number, bool, null, or object)
fn parseArrayElement(elem: []const u8, allocator: Allocator, owned_strings: *std.ArrayList([]u8)) ParseError!JsonValue {
    if (elem.len == 0) return error.InvalidJSON;
    return switch (elem[0]) {
        '{' => JsonValue{ .object = try parseObject(elem, allocator) },
        '"' => blk: {
            if (elem.len < 2 or elem[elem.len - 1] != '"') return error.MalformedString;
            const raw = elem[1 .. elem.len - 1];
            const has_escape = hasJsonEscape(raw);
            const value = if (has_escape) try decodeOwnedJsonString(raw, allocator) else raw;
            if (has_escape) try owned_strings.append(allocator, @constCast(value));
            break :blk JsonValue{ .string = value };
        },
        else => {
            if (std.mem.eql(u8, elem, "null")) return JsonValue{ .null_value = {} };
            if (std.mem.eql(u8, elem, "true")) return JsonValue{ .bool_value = true };
            if (std.mem.eql(u8, elem, "false")) return JsonValue{ .bool_value = false };
            return JsonValue{ .number = elem }; // zero-copy slice
        },
    };
}

fn advanceTokenIndex(tokens: []simd.Token, i: *usize, min_pos: usize) void {
    while (i.* < tokens.len and tokens[i.*].pos < min_pos) i.* += 1;
}

pub fn findStringEnd(line: []const u8, start: usize) ?usize {
    var idx = start;
    var escaped = false;
    while (idx < line.len) : (idx += 1) {
        const c = line[idx];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') return idx;
    }
    return null;
}

fn findStringEndFromTokens(line: []const u8, tokens: []simd.Token, token_start: usize, string_start: usize) ?usize {
    if (token_start < tokens.len and tokens[token_start].type == .quote and !isEscapedAt(line, tokens[token_start].pos)) {
        return tokens[token_start].pos;
    }
    return findStringEnd(line, string_start);
}

pub fn isEscapedAt(line: []const u8, pos: usize) bool {
    if (pos == 0) return false;
    var backslashes: usize = 0;
    var idx = pos;
    while (idx > 0) {
        idx -= 1;
        if (line[idx] != '\\') break;
        backslashes += 1;
    }
    return backslashes % 2 == 1;
}

pub fn hasJsonEscape(raw: []const u8) bool {
    return std.mem.indexOfScalar(u8, raw, '\\') != null;
}

/// Vectorized quote search (`std.mem.indexOfScalarPos`, SIMD-backed)
/// plus a cheap backward escape-check only on an actual hit — the
/// string equivalent of CSV's comma search, instead of a manual
/// per-byte escape-tracking loop. Unescaped strings (the common case)
/// resolve on the FIRST hit, so the backward scan almost never runs
/// more than the single "is there a backslash right before this quote"
/// check. Only finds where the string ENDS — callers still separately
/// check `hasJsonEscape` on the resulting span, since a legitimately-
/// unescaped closing quote can still follow an interior escape
/// sequence (`"foo\nbar"`) that needs real decoding.
pub fn findQuoteEnd(line: []const u8, start: usize) ?usize {
    var idx = start;
    while (std.mem.indexOfScalarPos(u8, line, idx, '"')) |q| {
        if (!isEscapedAt(line, q)) return q;
        idx = q + 1;
    }
    return null;
}

/// Single-pass byte scan straight into `field_buf`, matching CSV's own
/// comma-splitting approach instead of building generic JSON structures
/// (Token array, Field-struct array, JsonValue tags) for data callers
/// only ever read back as raw text. Real NDJSON files overwhelmingly
/// keep the same key order every row (same producer, same struct/
/// schema) — when `header[k]` matches the row's k-th key, this resolves
/// with zero allocation and no hashing at all. Returns `false` (leaving
/// `field_buf` in a partially-written, about-to-be-overwritten state —
/// callers always re-derive from the full generic parser on `false`, so
/// this is safe) the instant anything doesn't match the fast shape: a
/// header-order/name mismatch, an escaped string, a nested value, or
/// anything malformed. Never the source of truth for correctness — only
/// ever a speed shortcut the caller can discard. Originally private to
/// `NdjsonScanner` (ndjson.zig); pulled out here so `parallel.zig`'s
/// worker contexts can use the identical fast path instead of always
/// paying full generic-parser cost (see ROADMAP.md for the measured win
/// this closed).
pub fn tryFastRow(line: []const u8, header: []const []const u8, field_buf: [][]const u8) bool {
    var pos: usize = std.mem.indexOfScalar(u8, line, '{') orelse return false;
    pos += 1;

    for (header, 0..) |want_key, k| {
        while (pos < line.len and (line[pos] == ' ' or line[pos] == ',')) : (pos += 1) {}
        if (pos >= line.len or line[pos] != '"') return false;
        const key_start = pos + 1;
        const key_end = findQuoteEnd(line, key_start) orelse return false;
        const key = line[key_start..key_end];
        if (hasJsonEscape(key)) return false;
        if (!std.mem.eql(u8, key, want_key)) return false;
        pos = key_end + 1;

        while (pos < line.len and line[pos] == ' ') : (pos += 1) {}
        if (pos >= line.len or line[pos] != ':') return false;
        pos += 1;
        while (pos < line.len and line[pos] == ' ') : (pos += 1) {}
        if (pos >= line.len) return false;

        if (line[pos] == '"') {
            const val_start = pos + 1;
            const val_end = findQuoteEnd(line, val_start) orelse return false;
            const raw = line[val_start..val_end];
            if (hasJsonEscape(raw)) return false;
            field_buf[k] = raw;
            pos = val_end + 1;
        } else if (line[pos] == '{' or line[pos] == '[') {
            return false; // nested — fall back to the generic path, which errors correctly
        } else {
            const val_start = pos;
            while (pos < line.len and line[pos] != ',' and line[pos] != '}' and line[pos] != ' ') : (pos += 1) {}
            if (pos == val_start) return false;
            field_buf[k] = line[val_start..pos];
        }
    }
    return true;
}

fn decodeOwnedJsonString(raw: []const u8, allocator: Allocator) ParseError![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c != '\\') {
            try out.append(allocator, c);
            continue;
        }

        i += 1;
        if (i >= raw.len) return error.InvalidEscape;
        switch (raw[i]) {
            '"' => try out.append(allocator, '"'),
            '\\' => try out.append(allocator, '\\'),
            '/' => try out.append(allocator, '/'),
            'b' => try out.append(allocator, 0x08),
            'f' => try out.append(allocator, 0x0c),
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            'u' => {
                if (i + 4 >= raw.len) return error.InvalidUnicodeEscape;
                const code = std.fmt.parseInt(u21, raw[i + 1 .. i + 5], 16) catch return error.InvalidUnicodeEscape;
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(code, &utf8_buf) catch return error.InvalidUnicodeEscape;
                try out.appendSlice(allocator, utf8_buf[0..len]);
                i += 4;
            },
            else => return error.InvalidEscape,
        }
    }

    return try out.toOwnedSlice(allocator);
}

/// Old parseValue function - keeping for reference but unused
fn parseValue(line: []const u8, tokens: []simd.Token, i: *usize, allocator: Allocator) !JsonValue {
    _ = line;
    _ = tokens;
    _ = i;
    _ = allocator;
    return error.OldFunctionNotUsed;
}

/// Helper to get integer value from JsonValue
pub fn getInt(value: JsonValue) !i64 {
    return switch (value) {
        .number => |n| try simd.parseIntFast(n),
        else => error.NotANumber,
    };
}

/// Helper to get float value from JsonValue
pub fn getFloat(value: JsonValue) !f64 {
    return switch (value) {
        .number => |n| try simd.parseFloatFast(n),
        else => error.NotANumber,
    };
}

/// Helper to get string value from JsonValue
pub fn getString(value: JsonValue) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.NotAString,
    };
}

/// Helper to get bool value from JsonValue
pub fn getBool(value: JsonValue) !bool {
    return switch (value) {
        .bool_value => |b| b,
        else => error.NotABoolean,
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "parse simple object" {
    const line = "{\"name\":\"Alice\",\"age\":30}";
    var obj = try parseObject(line, std.testing.allocator);
    defer obj.deinit();

    // Check field count
    try std.testing.expectEqual(@as(usize, 2), obj.fields.len);

    // Check name field
    const name_value = obj.get("name") orelse return error.FieldNotFound;
    const name = try getString(name_value);
    try std.testing.expectEqualStrings("Alice", name);

    // Check age field
    const age_value = obj.get("age") orelse return error.FieldNotFound;
    const age = try getInt(age_value);
    try std.testing.expectEqual(@as(i64, 30), age);
}

test "parse object with boolean and null" {
    const line = "{\"active\":true,\"deleted\":false,\"metadata\":null}";
    var obj = try parseObject(line, std.testing.allocator);
    defer obj.deinit();

    try std.testing.expectEqual(@as(usize, 3), obj.fields.len);

    const active = try getBool(obj.get("active").?);
    try std.testing.expect(active);

    const deleted = try getBool(obj.get("deleted").?);
    try std.testing.expect(!deleted);

    const metadata = obj.get("metadata").?;
    try std.testing.expectEqual(JsonValue.null_value, metadata);
}

test "parse object with float" {
    const line = "{\"price\":19.99,\"discount\":0.1}";
    var obj = try parseObject(line, std.testing.allocator);
    defer obj.deinit();

    const price = try getFloat(obj.get("price").?);
    try std.testing.expectApproxEqAbs(@as(f64, 19.99), price, 0.01);

    const discount = try getFloat(obj.get("discount").?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), discount, 0.01);
}

test "parse real NDJSON line from sample" {
    const line = "{\"id\":1,\"name\":\"Alice\",\"age\":30,\"city\":\"NYC\",\"active\":true}";
    var obj = try parseObject(line, std.testing.allocator);
    defer obj.deinit();

    try std.testing.expectEqual(@as(usize, 5), obj.fields.len);

    try std.testing.expectEqual(@as(i64, 1), try getInt(obj.get("id").?));
    try std.testing.expectEqualStrings("Alice", try getString(obj.get("name").?));
    try std.testing.expectEqual(@as(i64, 30), try getInt(obj.get("age").?));
    try std.testing.expectEqualStrings("NYC", try getString(obj.get("city").?));
    try std.testing.expect(try getBool(obj.get("active").?));
}

test "zero-copy string value verification" {
    const line = "{\"key\":\"value\"}";
    var obj = try parseObject(line, std.testing.allocator);
    defer obj.deinit();

    const value_str = try getString(obj.fields[0].value);

    // Unescaped simple values stay zero-copy.
    const line_start = @intFromPtr(line.ptr);
    const line_end = line_start + line.len;

    const value_addr = @intFromPtr(value_str.ptr);

    try std.testing.expect(value_addr >= line_start and value_addr < line_end);
}

test "parse escaped JSON strings" {
    const line = "{\"full\\\"name\":\"Alice\\nAdmin\",\"path\":\"C:\\\\tmp\",\"unicode\":\"A\\u0042\"}";
    var obj = try parseObject(line, std.testing.allocator);
    defer obj.deinit();

    try std.testing.expectEqualStrings("full\"name", obj.fields[0].key);
    try std.testing.expectEqualStrings("Alice\nAdmin", try getString(obj.get("full\"name").?));
    try std.testing.expectEqualStrings("C:\\tmp", try getString(obj.get("path").?));
    try std.testing.expectEqualStrings("AB", try getString(obj.get("unicode").?));
}

test "parse escaped string in array" {
    const line = "{\"tags\":[\"alpha\",\"line\\nbreak\"]}";
    var obj = try parseObject(line, std.testing.allocator);
    defer obj.deinit();

    const tags = obj.get("tags").?.array;
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("alpha", try getString(tags[0]));
    try std.testing.expectEqualStrings("line\nbreak", try getString(tags[1]));
}
