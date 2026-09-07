//! Optional limits for the serial scanners. These bound individual
//! records, not materialized query results or total process memory.
const std = @import("std");

pub const LimitError = error{ RecordTooLarge, TooManyFields };

pub const InputLimits = struct {
    /// Bytes before LF, including a CR in CRLF. For JSON arrays this is
    /// the object text including its braces, not surrounding separators.
    max_record_bytes: ?usize = null,
    /// CSV fields or top-level JSON object members, including extra keys
    /// not in the first row's schema. Zero permits no fields.
    max_fields: ?usize = null,

    /// Compatibility default; null explicitly disables each limit.
    pub const unlimited: InputLimits = .{};
    pub const recommended: InputLimits = .{
        .max_record_bytes = 16 * 1024 * 1024,
        .max_fields = 4096,
    };

    pub fn enabled(self: InputLimits) bool {
        return self.max_record_bytes != null or self.max_fields != null;
    }

    /// Check before append/allocation, without overflowing current+extra.
    pub fn checkRecord(self: InputLimits, current: usize, extra: usize) LimitError!void {
        if (self.max_record_bytes) |max| {
            if (current > max or extra > max - current) return error.RecordTooLarge;
        }
    }

    pub fn checkField(self: InputLimits, count: usize) LimitError!void {
        if (self.max_fields) |max| {
            if (count >= max) return error.TooManyFields;
        }
    }

    /// Allocation-free guard before the JSON parser decodes strings or
    /// builds field arrays. This counts top-level members, not nested
    /// members or colons inside strings. It is not a syntax validator.
    pub fn checkJsonFields(self: InputLimits, line: []const u8) LimitError!void {
        if (self.max_fields == null) return;
        var depth: usize = 0;
        var count: usize = 0;
        var in_string = false;
        var escape = false;
        for (line) |c| {
            if (in_string) {
                if (escape) {
                    escape = false;
                } else if (c == '\\') {
                    escape = true;
                } else if (c == '"') {
                    in_string = false;
                }
                continue;
            }
            switch (c) {
                '"' => in_string = true,
                '{', '[' => depth += 1,
                '}', ']' => depth -|= 1,
                ':' => if (depth == 1) {
                    try self.checkField(count);
                    count += 1;
                },
                else => {},
            }
        }
    }
};

test "record limit checks inclusive boundaries without overflow" {
    const limits: InputLimits = .{ .max_record_bytes = 10 };
    try limits.checkRecord(7, 3);
    try std.testing.expectError(error.RecordTooLarge, limits.checkRecord(7, 4));
    try std.testing.expectError(error.RecordTooLarge, limits.checkRecord(std.math.maxInt(usize), 1));
    try InputLimits.unlimited.checkRecord(std.math.maxInt(usize), 1);
}

test "JSON field limit ignores strings and nested members" {
    const limits: InputLimits = .{ .max_fields = 2 };
    try limits.checkJsonFields("{\"a\":\"quoted \\\" : value\",\"b\":{\"x\":1,\"y\":2}}");
    try std.testing.expectError(error.TooManyFields, limits.checkJsonFields("{\"a\":1,\"b\":2,\"c\":3}"));
    try (InputLimits{ .max_fields = 0 }).checkJsonFields("{}");
    try std.testing.expectError(error.TooManyFields, (InputLimits{ .max_fields = 0 }).checkJsonFields("{\"a\":1}"));
}
