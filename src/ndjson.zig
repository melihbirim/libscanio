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
//! Parsing is json_parser.zig — a SIMD-tokenized, zero-copy JSON parser
//! (string/number values are slices directly into the mapped line; only
//! escaped strings allocate) pulled in from zson, a prior project doing
//! exactly this job for exactly this reason. The first attempt here used
//! std.json.parseFromSlice per line and measured 400x slower than CSV
//! (42K rows/sec vs 17M) — building a tree per row, every row, is real
//! cost, not a rounding error. Reusing a parser that already solved this
//! beat re-deriving the solution from scratch.
//!
//! Second finding, worth stating since it's easy to reintroduce: swapping
//! in json_parser.zig alone did NOT fix the 42K rows/sec number — the
//! actual bottleneck was std.heap.GeneralPurposeAllocator, not the parsing
//! algorithm. GPA's per-allocation safety/tracking overhead dominates for
//! this workload (several small, short-lived allocations per row, 500K
//! rows) — swapping the *allocator* the caller passes to Query.open() from
//! GPA to std.heap.c_allocator took NDJSON from 42K to 2.78M rows/sec on
//! the same file with the same parser, a 66x difference from allocator
//! choice alone (CSV's own zero-copy path barely notices, since it barely
//! allocates either way). The C ABI (c_api.zig) already uses c_allocator
//! for an unrelated reason (GPA also faults when dlopen()'d — see #149 in
//! csvql's history), so Python/consumers of the C ABI get the fast path
//! automatically; a Zig caller building on Query directly does not unless
//! they choose the allocator themselves. Measure with whatever allocator
//! you intend to actually ship with, not whichever one is easiest to
//! write in a test.
//!
//! Nested objects/arrays are still out of scope (see the project's own
//! non-goals) and fail loudly with NestedValueNotSupported rather than
//! silently stringifying — json_parser.zig can parse them, libscanio
//! chooses not to expose them as flat row fields.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const scan = @import("root.zig");
const Row = scan.Row;
const json_parser = @import("json_parser.zig");
const json_array = @import("json_array.zig");

pub const NdjsonError = error{
    EmptyFile,
    InvalidJson,
    NestedValueNotSupported,
};

pub const NdjsonScanner = struct {
    allocator: Allocator,
    file: std.fs.File,
    data: []const u8,
    mapped: bool,
    pos: usize,
    header: [][]const u8,
    field_buf: [][]const u8 = &.{},
    /// Backs each row's decoded-string bytes (escaped-string copies from
    /// parseObjectReuse). Reset (not deinit'd) at the start of every
    /// next(), retaining its capacity, matching the previous
    /// JsonObject.deinit() timing exactly — the previous row's data
    /// (already handed to the caller via field_buf) stays valid until then.
    row_arena: std.heap.ArenaAllocator,
    /// The JSON fields array for the CURRENT row, reused across next()
    /// calls via clearRetainingCapacity() rather than reallocated —
    /// parseObject()'s own internal array allocation was still a
    /// malloc/free pair per row even after row_arena existed, since the
    /// array itself was freshly requested and detached (toOwnedSlice())
    /// every call. Grown via self.allocator (persists for the scanner's
    /// whole lifetime), not row_arena (which resets every row and would
    /// defeat the reuse).
    ///
    /// owned_strings is NOT a persisted field alongside it, on purpose:
    /// json_parser's parseValueAfterColon() grows that list using
    /// whatever single allocator it's handed, which for parseObjectReuse
    /// is row_arena — so owned_strings' own backing array ends up
    /// arena-scoped too, and freeing it later via self.allocator (a
    /// different allocator than whatever actually backed it) segfaults.
    /// Caught by this file's own test suite. It's declared fresh,
    /// arena-backed, inside next() instead — cheap, since arena
    /// allocation is a bump pointer, and its whole lifetime is one row
    /// anyway.
    parse_fields: std.ArrayList(json_parser.JsonObject.Field) = .{},

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

        // JSON array ([{...},{...}]) vs NDJSON, sniffed from content, not
        // extension — a .json file could legitimately be either. Arrays
        // are converted to NDJSON text once, up front; everything below
        // this point (header derivation, next(), row_arena) is unaware
        // the source was ever an array at all. See json_array.zig.
        if (json_array.detectFormat(data) == .json_array) {
            const converted = try json_array.jsonArrayToNdjson(data, allocator);
            if (mapped) {
                std.posix.munmap(@alignCast(@constCast(data)));
            } else {
                allocator.free(@constCast(data));
            }
            data = converted;
            mapped = false;
            if (data.len == 0) return NdjsonError.EmptyFile;
        }

        var scanner = NdjsonScanner{
            .allocator = allocator,
            .file = file,
            .data = data,
            .mapped = mapped,
            .pos = 0,
            .header = &[_][]const u8{},
            .row_arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer scanner.row_arena.deinit();

        // Peek the first row to derive the header, then rewind — the
        // first data row is re-read normally by the first next() call.
        const first_line = scanner.nextLine() orelse return NdjsonError.EmptyFile;
        scanner.pos = 0;
        var obj = json_parser.parseObject(first_line, allocator) catch return NdjsonError.InvalidJson;
        defer obj.deinit();
        var keys = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, obj.fields.len);
        errdefer keys.deinit(allocator);
        for (obj.fields) |field| {
            try keys.append(allocator, try allocator.dupe(u8, field.key));
        }
        scanner.header = try keys.toOwnedSlice(allocator);
        return scanner;
    }

    pub fn deinit(self: *NdjsonScanner) void {
        self.row_arena.deinit();
        self.parse_fields.deinit(self.allocator);
        for (self.header) |k| self.allocator.free(k);
        self.allocator.free(self.header);
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
        _ = self.row_arena.reset(.retain_capacity);
        // Arena-backed and local, not a persisted field — see parse_fields'
        // doc comment for why owned_strings can't safely be reused the
        // same way.
        var owned_strings: std.ArrayList([]u8) = .{};
        const obj = json_parser.parseObjectReuse(
            line,
            self.allocator,
            self.row_arena.allocator(),
            &self.parse_fields,
            &owned_strings,
        ) catch return NdjsonError.InvalidJson;

        self.ensureCapacity(self.header.len);
        for (self.header, 0..) |key, i| {
            const val = obj.get(key) orelse {
                self.field_buf[i] = "";
                continue;
            };
            self.field_buf[i] = try render(val);
        }
        return Row{ .fields = self.field_buf[0..self.header.len] };
    }

    fn render(val: json_parser.JsonValue) ![]const u8 {
        return switch (val) {
            .string => |s| s,
            .number => |s| s, // already a zero-copy text slice — no formatting needed
            .null_value => "",
            .bool_value => |b| if (b) "true" else "false",
            .array, .object => NdjsonError.NestedValueNotSupported,
        };
    }

    fn ensureCapacity(self: *NdjsonScanner, n: usize) void {
        if (n <= self.field_buf.len) return;
        self.field_buf = self.allocator.realloc(self.field_buf, n) catch return;
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

test "ndjson: escaped strings decode correctly" {
    const allocator = std.testing.allocator;
    const path = "test_ndjson_escape.ndjson";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
        \\{"note":"line1\nline2","quote":"she said \"hi\""}
        \\
    });
    defer std.fs.cwd().deleteFile(path) catch {};

    var s = try NdjsonScanner.open(allocator, path);
    defer s.deinit();
    const row = (try s.next()).?;
    try std.testing.expectEqualStrings("line1\nline2", row.get(0).?);
    try std.testing.expectEqualStrings("she said \"hi\"", row.get(1).?);
}
