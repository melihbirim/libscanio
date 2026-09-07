//! Shared batch transport. A byte target is checked after each row;
//! one oversized row is returned whole. Callers must close on error.
const std = @import("std");
const validation = @import("validate.zig");

pub const Options = struct {
    max_rows: usize = 1024,
    target_bytes: usize = 1024 * 1024,

    pub fn check(self: Options) !void {
        if (self.max_rows == 0 or self.max_rows > 65536 or self.target_bytes == 0)
            return error.InvalidBatchSize;
    }
};

/// Owned JSON, or null at EOF. Rows are serialized before the source
/// advances, so no borrowed scanner slices survive a next() call.
pub fn readJson(allocator: std.mem.Allocator, source: anytype, comptime validated: bool, options: Options) !?[]u8 {
    return readJsonInner(allocator, source, validated, options) catch |err| {
        // Allocating writer has no I/O: WriteFailed means allocation failed.
        if (err == error.WriteFailed) return error.OutOfMemory;
        return err;
    };
}

fn readJsonInner(allocator: std.mem.Allocator, source: anytype, comptime validated: bool, options: Options) !?[]u8 {
    try options.check();
    var aw = std.io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeByte('[');
    var count: usize = 0;
    while (count < options.max_rows) {
        const item = (try source.next()) orelse break;
        if (count > 0) try w.writeByte(',');
        if (validated) try w.print("{{\"number\":{d},\"values\":", .{item.number});
        const fields = if (validated) item.row.fields else item.fields;
        try w.writeByte('[');
        for (fields, 0..) |field, i| {
            if (i > 0) try w.writeByte(',');
            try std.json.Stringify.value(field, .{}, w);
        }
        try w.writeByte(']');
        if (validated) {
            if (item.errors.len > 0) {
                try w.writeAll(",\"errors\":");
                try validation.writeRowErrorsJson(w, item.errors);
            }
            try w.writeByte('}');
        }
        count += 1;
        if (aw.written().len >= options.target_bytes) break;
    }
    if (count == 0) return null;
    try w.writeByte(']');
    return try aw.toOwnedSlice();
}

const TestSource = struct {
    left: usize = 3,
    pub fn next(self: *TestSource) !?struct { fields: []const []const u8 } {
        if (self.left == 0) return null;
        self.left -= 1;
        return .{ .fields = &.{ "quote\"", "nul\x00", "Zürich" } };
    }
};

fn allocationCase(allocator: std.mem.Allocator) !void {
    var source = TestSource{};
    const data = (try readJson(allocator, &source, false, .{})).?;
    defer allocator.free(data);
}

test "batch allocation failures release partial output" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

test "batch byte target includes a whole row and makes progress" {
    var source = TestSource{};
    var count: usize = 0;
    while (try readJson(std.testing.allocator, &source, false, .{ .target_bytes = 1 })) |data| {
        defer std.testing.allocator.free(data);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, data, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
        try std.testing.expectEqualStrings("nul\x00", parsed.value.array.items[0].array.items[1].string);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "invalid batch options do not consume source" {
    var source = TestSource{};
    try std.testing.expectError(error.InvalidBatchSize, readJson(std.testing.allocator, &source, false, .{ .max_rows = 0 }));
    try std.testing.expectError(error.InvalidBatchSize, readJson(std.testing.allocator, &source, false, .{ .target_bytes = 0 }));
    try std.testing.expectEqual(@as(usize, 3), source.left);
}
