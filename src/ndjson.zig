//! libscanio M4: NDJSON (newline-delimited JSON) — a second format behind
//! the same next()-based scan shape CSV already has.
//!
//! Schema model matches CSV's: the FIRST row's keys (in first-seen order)
//! become the "header" — later rows are matched by key name, not
//! position, since JSON key order within an object isn't guaranteed
//! stable the way CSV column position is. A row missing a header key
//! reads back as an empty string, same as CSV's own null/empty-field
//! convention.
//!
//! Deliberate scope cut, stated rather than hidden: this uses
//! std.json.parseFromSlice per line, not a hand-rolled zero-copy
//! tokenizer. CSV's Row.fields are slices directly into the mapped file
//! with zero per-row allocation; NDJSON's are not — each line gets parsed
//! into an owned std.json.Value tree, freed and replaced every next()
//! call. A true zero-copy JSON scanner (slicing unescaped string values
//! straight out of the buffer, only allocating when an escape sequence
//! forces it) is real, separate engineering — worth doing if a benchmark
//! ever shows this path matters, not before.
//!
//! Nested objects/arrays are out of scope (see the project's own
//! non-goals) and fail loudly with NestedValueNotSupported rather than
//! silently stringifying or dropping data.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const scan = @import("root.zig");
const Row = scan.Row;

pub const NdjsonError = error{
    EmptyFile,
    InvalidJson,
    NotAnObject,
    NestedValueNotSupported,
};

pub const NdjsonScanner = struct {
    allocator: Allocator,
    file: std.fs.File,
    data: []const u8,
    mapped: bool,
    pos: usize,
    header: [][]const u8,
    /// Rendered value per header column for the current row, reused/grown
    /// across next() calls for the non-string (number/bool/null) case —
    /// string values instead point directly at the current parse tree.
    render_buf: [][]u8 = &.{},
    field_buf: [][]const u8 = &.{},
    current: ?std.json.Parsed(std.json.Value) = null,

    pub fn open(allocator: Allocator, path: []const u8) !NdjsonScanner {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();
        const size = (try file.stat()).size;
        if (size == 0) return NdjsonError.EmptyFile;

        var data: []const u8 = undefined;
        var mapped = false;
        if (builtin.os.tag == .windows) {
            data = try file.readToEndAlloc(allocator, size);
        } else {
            data = try std.posix.mmap(null, size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, file.handle, 0);
            mapped = true;
        }

        var scanner = NdjsonScanner{
            .allocator = allocator,
            .file = file,
            .data = data,
            .mapped = mapped,
            .pos = 0,
            .header = &[_][]const u8{},
        };

        // Peek the first row to derive the header, then rewind — the
        // first data row is re-read normally by the first next() call.
        const first_line = scanner.nextLine() orelse return NdjsonError.EmptyFile;
        scanner.pos = 0;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, first_line, .{}) catch return NdjsonError.InvalidJson;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return NdjsonError.NotAnObject,
        };
        var keys = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, obj.count());
        errdefer keys.deinit(allocator);
        var it = obj.iterator();
        while (it.next()) |entry| {
            try keys.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
        }
        scanner.header = try keys.toOwnedSlice(allocator);
        return scanner;
    }

    pub fn deinit(self: *NdjsonScanner) void {
        if (self.current) |*c| c.deinit();
        for (self.header) |k| self.allocator.free(k);
        self.allocator.free(self.header);
        for (self.render_buf) |b| if (b.len > 0) self.allocator.free(b);
        if (self.render_buf.len > 0) self.allocator.free(self.render_buf);
        if (self.field_buf.len > 0) self.allocator.free(self.field_buf);
        if (self.mapped) {
            std.posix.munmap(@alignCast(@constCast(self.data)));
        } else {
            self.allocator.free(@constCast(self.data));
        }
        self.file.close();
    }

    pub fn columnIndex(self: NdjsonScanner, name: []const u8) ?usize {
        for (self.header, 0..) |h, i| {
            if (std.mem.eql(u8, h, name)) return i;
        }
        return null;
    }

    pub fn next(self: *NdjsonScanner) !?Row {
        const line = self.nextLine() orelse return null;
        if (self.current) |*c| c.deinit();
        self.current = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return NdjsonError.InvalidJson;
        const obj = switch (self.current.?.value) {
            .object => |o| o,
            else => return NdjsonError.NotAnObject,
        };

        self.ensureCapacity(self.header.len);
        for (self.header, 0..) |key, i| {
            const val = obj.get(key) orelse {
                self.field_buf[i] = "";
                continue;
            };
            self.field_buf[i] = try self.render(i, val);
        }
        return Row{ .fields = self.field_buf[0..self.header.len] };
    }

    fn render(self: *NdjsonScanner, i: usize, val: std.json.Value) ![]const u8 {
        return switch (val) {
            .string => |s| s,
            .null => "",
            .bool => |b| if (b) "true" else "false",
            .integer => |n| blk: {
                const s = std.fmt.bufPrint(self.render_buf[i], "{d}", .{n}) catch b: {
                    self.growRenderBuf(i, 32);
                    break :b std.fmt.bufPrint(self.render_buf[i], "{d}", .{n}) catch unreachable;
                };
                break :blk s;
            },
            .float => |f| blk: {
                const s = std.fmt.bufPrint(self.render_buf[i], "{d}", .{f}) catch b: {
                    self.growRenderBuf(i, 64);
                    break :b std.fmt.bufPrint(self.render_buf[i], "{d}", .{f}) catch unreachable;
                };
                break :blk s;
            },
            .number_string => |s| s,
            .array, .object => NdjsonError.NestedValueNotSupported,
        };
    }

    fn ensureCapacity(self: *NdjsonScanner, n: usize) void {
        if (n <= self.field_buf.len) return;
        self.field_buf = self.allocator.realloc(self.field_buf, n) catch return;
        const old_len = self.render_buf.len;
        self.render_buf = self.allocator.realloc(self.render_buf, n) catch return;
        for (self.render_buf[old_len..]) |*b| b.* = &.{};
        for (self.render_buf[old_len..]) |*b| {
            b.* = self.allocator.alloc(u8, 32) catch &.{};
        }
    }

    fn growRenderBuf(self: *NdjsonScanner, i: usize, min: usize) void {
        const grown = self.allocator.realloc(self.render_buf[i], min) catch return;
        self.render_buf[i] = grown;
    }

    fn nextLine(self: *NdjsonScanner) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        const rel = std.mem.indexOfScalar(u8, self.data[start..], '\n');
        if (rel) |r| {
            self.pos = start + r + 1;
            var end = start + r;
            if (end > start and self.data[end - 1] == '\r') end -= 1;
            return self.data[start..end];
        }
        self.pos = self.data.len;
        return self.data[start..];
    }
};

test "ndjson: header derived from first row, values read back correctly" {
    const allocator = std.testing.allocator;
    const path = "test_ndjson_basic.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"id":1,"name":"Alice","active":true}
        \\{"id":2,"name":"Bob","active":false}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var s = try NdjsonScanner.open(allocator, path);
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 3), s.header.len);
    try std.testing.expectEqual(@as(usize, 0), s.columnIndex("id").?);

    const row1 = (try s.next()).?;
    try std.testing.expectEqualStrings("1", row1.get(0).?);
    try std.testing.expectEqualStrings("Alice", row1.get(1).?);
    try std.testing.expectEqualStrings("true", row1.get(2).?);

    const row2 = (try s.next()).?;
    try std.testing.expectEqualStrings("2", row2.get(0).?);
    try std.testing.expectEqualStrings("false", row2.get(2).?);

    try std.testing.expectEqual(@as(?Row, null), try s.next());
}

test "ndjson: missing key reads back as empty string" {
    const allocator = std.testing.allocator;
    const path = "test_ndjson_missing_key.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"id":1,"note":"hi"}
        \\{"id":2}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var s = try NdjsonScanner.open(allocator, path);
    defer s.deinit();
    _ = try s.next();
    const row2 = (try s.next()).?;
    try std.testing.expectEqualStrings("", row2.get(1).?);
}

test "ndjson: nested object value fails loudly, not silently" {
    const allocator = std.testing.allocator;
    const path = "test_ndjson_nested.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"id":1,"meta":{"a":1}}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var s = try NdjsonScanner.open(allocator, path);
    defer s.deinit();
    try std.testing.expectError(NdjsonError.NestedValueNotSupported, s.next());
}

test "ndjson: float and negative numbers render correctly" {
    const allocator = std.testing.allocator;
    const path = "test_ndjson_numbers.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"price":19.99,"delta":-5}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var s = try NdjsonScanner.open(allocator, path);
    defer s.deinit();
    const row = (try s.next()).?;
    try std.testing.expectEqualStrings("19.99", row.get(0).?);
    try std.testing.expectEqualStrings("-5", row.get(1).?);
}
