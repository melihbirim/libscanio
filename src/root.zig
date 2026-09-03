//! libscanio M1: file source + CSV parser + next() + row streaming.
//!
//! Constant-memory by construction: the file is memory-mapped (POSIX) or
//! read once into a single allocated buffer (Windows, no mmap fallback
//! here), and every Row's fields are zero-copy slices into that one
//! buffer — no per-row allocation. The only allocation on the hot path is
//! the reusable field-offset scratch array, grown (not reallocated per
//! row) only if a row has more fields than any row seen so far.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const query_mod = @import("query.zig");
pub const Query = query_mod.Query;
pub const QueryOptions = query_mod.QueryOptions;
pub const Predicate = query_mod.Predicate;
pub const Op = query_mod.Op;

const ndjson_mod = @import("ndjson.zig");
pub const NdjsonScanner = ndjson_mod.NdjsonScanner;
pub const NdjsonError = ndjson_mod.NdjsonError;

test {
    _ = query_mod;
    _ = ndjson_mod;
}

pub const Row = struct {
    fields: []const []const u8,

    pub fn get(self: Row, index: usize) ?[]const u8 {
        if (index >= self.fields.len) return null;
        return self.fields[index];
    }
};

pub const ScanError = error{
    EmptyFile,
};

pub const Scanner = struct {
    allocator: Allocator,
    file: std.fs.File,
    data: []const u8,
    mapped: bool,
    pos: usize,
    delimiter: u8,
    header: [][]const u8,
    field_buf: [][]const u8,

    pub fn open(allocator: Allocator, path: []const u8) !Scanner {
        return openWithDelimiter(allocator, path, ',');
    }

    pub fn openWithDelimiter(allocator: Allocator, path: []const u8, delimiter: u8) !Scanner {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();
        const size = (try file.stat()).size;
        if (size == 0) return ScanError.EmptyFile;

        var data: []const u8 = undefined;
        var mapped = false;
        if (builtin.os.tag == .windows) {
            data = try file.readToEndAlloc(allocator, size);
        } else {
            const mem = try std.posix.mmap(
                null,
                size,
                std.posix.PROT.READ,
                .{ .TYPE = .PRIVATE },
                file.handle,
                0,
            );
            data = mem;
            mapped = true;
        }

        var scanner = Scanner{
            .allocator = allocator,
            .file = file,
            .data = data,
            .mapped = mapped,
            .pos = 0,
            .delimiter = delimiter,
            .header = &[_][]const u8{},
            .field_buf = &[_][]const u8{},
        };

        const header_line = scanner.nextLine() orelse return ScanError.EmptyFile;
        scanner.header = try scanner.splitOwned(header_line);
        return scanner;
    }

    pub fn deinit(self: *Scanner) void {
        self.allocator.free(self.header);
        if (self.field_buf.len > 0) self.allocator.free(self.field_buf);
        if (self.mapped) {
            std.posix.munmap(@alignCast(@constCast(self.data)));
        } else {
            self.allocator.free(@constCast(self.data));
        }
        self.file.close();
    }

    pub fn columnIndex(self: Scanner, name: []const u8) ?usize {
        for (self.header, 0..) |h, i| {
            if (std.mem.eql(u8, h, name)) return i;
        }
        return null;
    }

    /// Returns the next row, or null at EOF. The returned Row's fields
    /// slice is only valid until the next call to next() — it's a reused
    /// scratch buffer, not a fresh allocation per row.
    pub fn next(self: *Scanner) !?Row {
        const line = self.nextLine() orelse return null;
        const n = self.splitInto(line);
        return Row{ .fields = self.field_buf[0..n] };
    }

    fn nextLine(self: *Scanner) ?[]const u8 {
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

    /// Split a line into the reusable field_buf, growing it if this row
    /// has more fields than any row seen so far. Returns the field count.
    fn splitInto(self: *Scanner, line: []const u8) usize {
        var count: usize = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= line.len) : (i += 1) {
            if (i == line.len or line[i] == self.delimiter) {
                self.ensureFieldCapacity(count + 1);
                self.field_buf[count] = line[start..i];
                count += 1;
                start = i + 1;
            }
        }
        return count;
    }

    fn ensureFieldCapacity(self: *Scanner, needed: usize) void {
        if (needed <= self.field_buf.len) return;
        const grown = self.allocator.realloc(self.field_buf, needed) catch return;
        self.field_buf = grown;
    }

    /// One-shot split that owns its own slice (used only for the header).
    fn splitOwned(self: *Scanner, line: []const u8) ![][]const u8 {
        var list = std.ArrayListUnmanaged([]const u8){};
        errdefer list.deinit(self.allocator);
        var start: usize = 0;
        var i: usize = 0;
        while (i <= line.len) : (i += 1) {
            if (i == line.len or line[i] == self.delimiter) {
                try list.append(self.allocator, line[start..i]);
                start = i + 1;
            }
        }
        return list.toOwnedSlice(self.allocator);
    }
};

test "scans a simple CSV, header parsed, rows streamed" {
    const allocator = std.testing.allocator;
    const path = "test_simple.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,name\n1,Alice\n2,Bob\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var scanner = try Scanner.open(allocator, path);
    defer scanner.deinit();

    try std.testing.expectEqual(@as(usize, 2), scanner.header.len);
    try std.testing.expectEqualStrings("id", scanner.header[0]);
    try std.testing.expectEqualStrings("name", scanner.header[1]);
    try std.testing.expectEqual(@as(usize, 0), scanner.columnIndex("id").?);
    try std.testing.expectEqual(@as(usize, 1), scanner.columnIndex("name").?);
    try std.testing.expectEqual(@as(?usize, null), scanner.columnIndex("nope"));

    const row1 = (try scanner.next()).?;
    try std.testing.expectEqualStrings("1", row1.get(0).?);
    try std.testing.expectEqualStrings("Alice", row1.get(1).?);

    const row2 = (try scanner.next()).?;
    try std.testing.expectEqualStrings("2", row2.get(0).?);
    try std.testing.expectEqualStrings("Bob", row2.get(1).?);

    try std.testing.expectEqual(@as(?Row, null), try scanner.next());
}

test "handles CRLF line endings" {
    const allocator = std.testing.allocator;
    const path = "test_crlf.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "a,b\r\n1,2\r\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var scanner = try Scanner.open(allocator, path);
    defer scanner.deinit();

    const row = (try scanner.next()).?;
    try std.testing.expectEqualStrings("1", row.get(0).?);
    try std.testing.expectEqualStrings("2", row.get(1).?);
}

test "file with no trailing newline still yields the last row" {
    const allocator = std.testing.allocator;
    const path = "test_no_trailing_nl.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "a,b\n1,2" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var scanner = try Scanner.open(allocator, path);
    defer scanner.deinit();

    const row = (try scanner.next()).?;
    try std.testing.expectEqualStrings("1", row.get(0).?);
    try std.testing.expectEqualStrings("2", row.get(1).?);
    try std.testing.expectEqual(@as(?Row, null), try scanner.next());
}

test "empty file returns EmptyFile error" {
    const allocator = std.testing.allocator;
    const path = "test_empty.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "" });
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.testing.expectError(ScanError.EmptyFile, Scanner.open(allocator, path));
}

test "custom delimiter (tab)" {
    const allocator = std.testing.allocator;
    const path = "test_tsv.tsv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "a\tb\n1\t2\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var scanner = try Scanner.openWithDelimiter(allocator, path, '\t');
    defer scanner.deinit();

    const row = (try scanner.next()).?;
    try std.testing.expectEqualStrings("1", row.get(0).?);
    try std.testing.expectEqualStrings("2", row.get(1).?);
}

test "row field count varies across rows (ragged CSV) without leaking stale fields" {
    const allocator = std.testing.allocator;
    const path = "test_ragged.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "a,b,c\n1,2,3\n4,5\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var scanner = try Scanner.open(allocator, path);
    defer scanner.deinit();

    const row1 = (try scanner.next()).?;
    try std.testing.expectEqual(@as(usize, 3), row1.fields.len);

    const row2 = (try scanner.next()).?;
    try std.testing.expectEqual(@as(usize, 2), row2.fields.len);
}
