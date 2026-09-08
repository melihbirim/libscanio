const std = @import("std");
const scan = @import("root.zig");
const csv = @import("csv.zig");
const a = std.testing.allocator;

const Fixture = struct {
    dir: std.testing.TmpDir,
    path: []u8,

    fn init(name: []const u8, data: []const u8) !Fixture {
        var dir = std.testing.tmpDir(.{});
        errdefer dir.cleanup();
        try dir.dir.writeFile(.{ .sub_path = name, .data = data });
        const base = try dir.dir.realpathAlloc(a, ".");
        defer a.free(base);
        return .{ .dir = dir, .path = try std.fs.path.join(a, &.{ base, name }) };
    }

    fn deinit(self: *Fixture) void {
        a.free(self.path);
        self.dir.cleanup();
    }
};

test "CSV record limits are inclusive at every chunk boundary and terminal" {
    var f = try Fixture.init("limits.csv", "a,b\n123,45\n1234,56");
    defer f.deinit();
    for ([_]usize{ 1, 2, 3, 7, 64 }) |chunk| {
        var s = try scan.Scanner.openWithOptions(a, f.path, .{
            .chunk_size = chunk,
            .limits = .{ .max_record_bytes = 6 },
        });
        defer s.deinit();
        const row = (try s.next()).?;
        try std.testing.expectEqualStrings("123", row.get(0).?);
        try std.testing.expectError(error.RecordTooLarge, s.next());
        try std.testing.expectError(error.RecordTooLarge, s.next());
        try std.testing.expectError(error.RecordTooLarge, s.countRemaining());
        try std.testing.expect(s.line_scratch.items.len <= 6);
    }
}

test "headers have the same record and field limits as data" {
    var csv_file = try Fixture.init("limits.csv", "a,b\n1,2\n");
    defer csv_file.deinit();
    try std.testing.expectError(error.RecordTooLarge, scan.Scanner.openWithOptions(a, csv_file.path, .{
        .chunk_size = 1,
        .limits = .{ .max_record_bytes = 2 },
    }));
    try std.testing.expectError(error.TooManyFields, scan.Scanner.openWithOptions(a, csv_file.path, .{
        .limits = .{ .max_fields = 1 },
    }));
    var json_file = try Fixture.init("limits.ndjson", "{\"a\":1,\"b\":2}\n");
    defer json_file.deinit();
    try std.testing.expectError(error.RecordTooLarge, scan.NdjsonScanner.openWithOptions(a, json_file.path, .{
        .chunk_size = 2,
        .limits = .{ .max_record_bytes = 6 },
    }));
    try std.testing.expectError(error.TooManyFields, scan.NdjsonScanner.openWithOptions(a, json_file.path, .{
        .limits = .{ .max_fields = 1 },
    }));
}

test "CSV field limit counts empty and quoted fields and projected tails" {
    var f = try Fixture.init("limits.csv", "a,b\n\"x,y\",\"a\"\"b\"\n1,2,\n");
    defer f.deinit();
    var q = try scan.Query.open(a, f.path, .{
        .columns = &.{0},
        .stop_after_column = 0,
        .limits = .{ .max_fields = 2 },
    });
    defer q.deinit();
    try std.testing.expectEqualStrings("x,y", (try q.next()).?.get(0).?);
    try std.testing.expectError(error.TooManyFields, q.next());
    try std.testing.expectError(error.TooManyFields, q.count());
}

test "limit checks precede record and escape allocations" {
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var scratch: std.ArrayListUnmanaged(u8) = .{};
    defer scratch.deinit(a);
    try std.testing.expectError(error.RecordTooLarge, csv.FieldIterator.initWithLimits(
        failing.allocator(),
        "\"a\"\"b\"",
        ',',
        &scratch,
        .{ .max_record_bytes = 1 },
    ));
    var it = try csv.FieldIterator.initWithLimits(
        failing.allocator(),
        "\"a\"\"b\"",
        ',',
        &scratch,
        .{ .max_fields = 0 },
    );
    try std.testing.expectError(error.TooManyFields, it.next());
    try std.testing.expectEqual(@as(usize, 0), scratch.capacity);
}

test "NDJSON and JSON array record limits agree across chunk sizes" {
    for ([_]bool{ false, true }) |array| {
        var f = try Fixture.init(if (array) "limits.json" else "limits.ndjson", if (array)
            "[{\"a\":1},{\"a\":22}]"
        else
            "{\"a\":1}\n{\"a\":22}");
        defer f.deinit();
        for ([_]usize{ 1, 2, 7, 8, 64 }) |chunk| {
            var q = try scan.Query.open(a, f.path, .{
                .json_chunk_size = chunk,
                .limits = .{ .max_record_bytes = 7 },
            });
            defer q.deinit();
            try std.testing.expectEqualStrings("1", (try q.next()).?.get(0).?);
            try std.testing.expectError(error.RecordTooLarge, q.next());
            try std.testing.expectError(error.RecordTooLarge, q.count());
        }
    }
}

test "JSON field limits include extra keys beyond the schema and projection" {
    for ([_]bool{ false, true }) |array| {
        var f = try Fixture.init(if (array) "limits.json" else "limits.ndjson", if (array)
            "[{\"a\":\"x:y\"},{\"a\":\"z\",\"extra\":1}]"
        else
            "{\"a\":\"x:y\"}\n{\"a\":\"z\",\"extra\":1}\n");
        defer f.deinit();
        var q = try scan.Query.open(a, f.path, .{
            .columns = &.{0},
            .stop_after_column = 0,
            .limits = .{ .max_fields = 1 },
        });
        defer q.deinit();
        try std.testing.expectEqualStrings("x:y", (try q.next()).?.get(0).?);
        try std.testing.expectError(error.TooManyFields, q.next());
    }
}

test "count and filters cannot bypass active limits" {
    for ([_][]const u8{ "limits.csv", "limits.ndjson", "limits.json" }, 0..) |name, i| {
        var f = try Fixture.init(name, ([_][]const u8{
            "a\n1\n2,3\n", "{\"a\":1}\n{\"a\":2,\"b\":3}\n", "[{\"a\":1},{\"a\":2,\"b\":3}]",
        })[i]);
        defer f.deinit();
        for ([_]bool{ false, true }) |filtered| {
            const predicates = [_]scan.Predicate{scan.Predicate.init(0, .eq, "never")};
            var q = try scan.Query.open(a, f.path, .{
                .limits = .{ .max_fields = 1 },
                .where = if (filtered) &predicates else &.{},
            });
            defer q.deinit();
            try std.testing.expectError(error.TooManyFields, q.count());
        }
        // Query limits still stop consumption before a later bad record.
        var limited = try scan.Query.open(a, f.path, .{
            .limits = .{ .max_fields = 1 },
            .limit = 1,
        });
        defer limited.deinit();
        try std.testing.expectEqual(@as(usize, 1), try limited.count());
    }
}

test "CRLF byte accounting is identical for split and unsplit records" {
    var f = try Fixture.init("limits.csv", "a\r\n1\r\n");
    defer f.deinit();
    for ([_]usize{ 1, 2, 64 }) |chunk| {
        var s = try scan.Scanner.openWithOptions(a, f.path, .{
            .chunk_size = chunk,
            .limits = .{ .max_record_bytes = 2 },
        });
        defer s.deinit();
        try std.testing.expectEqualStrings("1", (try s.next()).?.get(0).?);
        try std.testing.expectEqual(@as(?scan.Row, null), try s.next());
        try std.testing.expectError(error.RecordTooLarge, scan.Scanner.openWithOptions(a, f.path, .{
            .chunk_size = chunk,
            .limits = .{ .max_record_bytes = 1 },
        }));
    }
}

test "explicit opt-out preserves the existing unrestricted scan" {
    var f = try Fixture.init("limits.csv", "a\n1,2,3\n");
    defer f.deinit();
    var q = try scan.Query.open(a, f.path, .{ .limits = scan.InputLimits.unlimited });
    defer q.deinit();
    try std.testing.expectEqual(@as(usize, 3), (try q.next()).?.fields.len);
    try std.testing.expectError(error.InvalidChunkSize, scan.Scanner.openWithOptions(a, f.path, .{ .chunk_size = 0 }));
    try std.testing.expectError(error.InvalidChunkSize, scan.NdjsonScanner.openWithOptions(a, f.path, .{ .chunk_size = 0 }));
}
