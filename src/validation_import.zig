//! Native routing of parsed rows to accepted CSV and rejected JSONL.
//! Outputs must not exist. On a reported failure, newly created outputs
//! are removed. No fsync/transactional publication guarantee is made.
const std = @import("std");
const validation = @import("validate.zig");
const csv = @import("csv.zig");

pub const Stats = extern struct {
    rows_total: u64 = 0,
    rows_valid: u64 = 0,
    rows_invalid: u64 = 0,
    errors_total: u64 = 0,
};

fn writeCsv(w: *std.io.Writer, fields: []const []const u8) !void {
    // csv.writer's single empty field must be distinguishable from no row.
    if (fields.len == 1 and fields[0].len == 0) {
        try w.writeAll("\"\"");
    } else {
        for (fields, 0..) |field, i| {
            if (i > 0) try w.writeByte(',');
            try csv.writeField(w, field, ',');
        }
    }
    try w.writeAll("\r\n");
}

pub fn run(allocator: std.mem.Allocator, source: []const u8, schema_json: []const u8, accepted: []const u8, rejected: []const u8) !Stats {
    var validator = try validation.Validator.openJson(allocator, source, schema_json);
    defer validator.deinit();
    // Exclusive creation also rejects symlinks/hardlinks to the input or
    // existing output, without needing racy path-identity comparisons.
    const dir = std.fs.cwd();
    const good = try dir.createFile(accepted, .{ .exclusive = true });
    errdefer dir.deleteFile(accepted) catch {};
    defer good.close();
    const bad = try dir.createFile(rejected, .{ .exclusive = true });
    errdefer dir.deleteFile(rejected) catch {};
    defer bad.close();
    var good_buffer: [64 * 1024]u8 = undefined;
    var bad_buffer: [64 * 1024]u8 = undefined;
    var good_writer = good.writer(&good_buffer);
    var bad_writer = bad.writer(&bad_buffer);
    const gw = &good_writer.interface;
    const bw = &bad_writer.interface;
    for (validator.header()) |name| if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidUtf8;
    try writeCsv(gw, validator.header());
    var stats = Stats{};
    while (try validator.next()) |item| {
        for (item.row.fields) |field| if (!std.unicode.utf8ValidateSlice(field)) return error.InvalidUtf8;
        if (item.isValid()) {
            try writeCsv(gw, item.row.fields);
        } else {
            // Arrays retain duplicate column names and ragged extra values.
            try bw.writeAll("{\"values\":[");
            for (item.row.fields, 0..) |field, i| {
                if (i > 0) try bw.writeByte(',');
                try std.json.Stringify.value(field, .{}, bw);
            }
            try bw.writeAll("],\"errors\":");
            try validation.writeRowErrorsJson(bw, item.errors);
            try bw.writeAll("}\n");
        }
        stats.errors_total += item.errors.len;
    }
    try gw.flush();
    try bw.flush();
    stats.rows_total = validator.row_number;
    stats.rows_valid = validator.rows_valid;
    stats.rows_invalid = validator.rows_invalid;
    return stats;
}

fn allocationCase(allocator: std.mem.Allocator, source: []const u8, good: []const u8, bad: []const u8) !void {
    const stats = run(allocator, source, "{\"a\":{\"type\":\"integer\"}}", good, bad) catch |e| {
        try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(good, .{}));
        try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(bad, .{}));
        // Constant valid JSON; BadSchema can only be parseSchema's
        // existing translation of an injected JSON allocation failure.
        if (e == error.BadSchema) return error.OutOfMemory;
        return e;
    };
    defer std.fs.cwd().deleteFile(good) catch {};
    defer std.fs.cwd().deleteFile(bad) catch {};
    try std.testing.expectEqual(@as(u64, 2), stats.rows_total);
    try std.testing.expectEqual(@as(u64, 1), stats.rows_invalid);
}

test "native import releases allocations and removes outputs on failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "source.csv", .data = "a\n1\nbad\n" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "source.csv" });
    defer std.testing.allocator.free(source);
    const good = try std.fs.path.join(std.testing.allocator, &.{ root, "good.csv" });
    defer std.testing.allocator.free(good);
    const bad = try std.fs.path.join(std.testing.allocator, &.{ root, "bad.jsonl" });
    defer std.testing.allocator.free(bad);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{ source, good, bad });
}
