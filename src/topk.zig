//! libscanio M7 (top-K): O(N log K) via a size-K heap, not a full sort —
//! adapted from csvql's TopKHeap (src/fast_sort.zig), minus its radix-sort
//! key machinery, which exists there to make the *general* ORDER BY case
//! fast and isn't needed for a numeric-only top-K at this scope.
//!
//! Real cost worth naming: unlike scan/filter/aggregate, top-K has to
//! retain K rows across the whole pass, and Row.fields point into a
//! reused per-row buffer that the next next() call overwrites — so a
//! candidate row has to be copied to survive being kept. The one
//! optimization applied against that cost: a row is only copied when it's
//! actually a heap candidate (checked against the current worst-kept key
//! first), not for every row scanned — for a large file and a small K,
//! most rows never get copied at all.
const std = @import("std");
const Allocator = std.mem.Allocator;
const scan = @import("root.zig");
const Query = scan.Query;
const Row = scan.Row;

pub const OwnedRow = struct {
    fields: [][]u8,
    allocator: Allocator,

    pub fn deinit(self: OwnedRow) void {
        for (self.fields) |f| self.allocator.free(f);
        self.allocator.free(self.fields);
    }

    pub fn get(self: OwnedRow, i: usize) ?[]const u8 {
        if (i >= self.fields.len) return null;
        return self.fields[i];
    }
};

pub fn copyRow(allocator: Allocator, row: Row) !OwnedRow {
    const fields = try allocator.alloc([]u8, row.fields.len);
    var filled: usize = 0;
    errdefer {
        for (fields[0..filled]) |f| allocator.free(f);
        allocator.free(fields);
    }
    for (row.fields, 0..) |f, i| {
        fields[i] = try allocator.dupe(u8, f);
        filled += 1;
    }
    return .{ .fields = fields, .allocator = allocator };
}

pub const Entry = struct { key: f64, row: OwnedRow };

pub const TopK = struct {
    allocator: Allocator,
    items: []Entry,
    len: usize = 0,
    capacity: usize,
    descending: bool,

    pub fn init(allocator: Allocator, k: usize, descending: bool) !TopK {
        return .{
            .allocator = allocator,
            .items = try allocator.alloc(Entry, k),
            .capacity = k,
            .descending = descending,
        };
    }

    pub fn deinit(self: *TopK) void {
        for (self.items[0..self.len]) |e| e.row.deinit();
        self.allocator.free(self.items);
    }

    /// Sorted best-to-worst. Sorts the heap contents in place — call once,
    /// after the scan that fed insertCandidate() is done.
    pub fn getSorted(self: *TopK) []Entry {
        const items = self.items[0..self.len];
        const desc = self.descending;
        std.mem.sort(Entry, items, desc, struct {
            fn lessThan(d: bool, a: Entry, b: Entry) bool {
                return if (d) a.key > b.key else a.key < b.key;
            }
        }.lessThan);
        return items;
    }

    fn isBetter(self: TopK, a: f64, b: f64) bool {
        return if (self.descending) a > b else a < b;
    }

    fn isWorse(self: TopK, a: f64, b: f64) bool {
        return if (self.descending) a < b else a > b;
    }

    /// True if `key` would actually make it into the top-K right now —
    /// callers use this to decide whether copying the row is worth it at
    /// all before doing that copy.
    pub fn wouldAccept(self: TopK, key: f64) bool {
        if (self.capacity == 0) return false;
        return self.len < self.capacity or self.isBetter(key, self.items[0].key);
    }

    fn insert(self: *TopK, key: f64, row: OwnedRow) void {
        if (self.capacity == 0) {
            row.deinit();
            return;
        }
        if (self.len < self.capacity) {
            self.items[self.len] = .{ .key = key, .row = row };
            self.len += 1;
            if (self.len == self.capacity) self.buildHeap();
            return;
        }
        if (self.isBetter(key, self.items[0].key)) {
            self.items[0].row.deinit();
            self.items[0] = .{ .key = key, .row = row };
            self.siftDown(0);
        } else {
            row.deinit();
        }
    }

    fn buildHeap(self: *TopK) void {
        if (self.len <= 1) return;
        var i: usize = self.len / 2;
        while (i > 0) {
            i -= 1;
            self.siftDown(i);
        }
    }

    fn siftDown(self: *TopK, start: usize) void {
        var pos = start;
        while (true) {
            var worst = pos;
            const left = 2 * pos + 1;
            const right = 2 * pos + 2;
            if (left < self.len and self.isWorse(self.items[left].key, self.items[worst].key)) worst = left;
            if (right < self.len and self.isWorse(self.items[right].key, self.items[worst].key)) worst = right;
            if (worst == pos) break;
            std.mem.swap(Entry, &self.items[pos], &self.items[worst]);
            pos = worst;
        }
    }
};

pub fn topK(allocator: Allocator, q: *Query, column: usize, k: usize, descending: bool) !TopK {
    var heap = try TopK.init(allocator, k, descending);
    errdefer heap.deinit();
    while (try q.next()) |row| {
        const field = row.get(column) orelse continue;
        const v = std.fmt.parseFloat(f64, field) catch continue;
        if (!heap.wouldAccept(v)) continue;
        const owned = try copyRow(allocator, row);
        heap.insert(v, owned);
    }
    return heap;
}

test "topk: descending, K < N" {
    const allocator = std.testing.allocator;
    const path = "test_topk_desc.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n3,900\n4,3000\n5,200\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    var heap = try topK(allocator, &q, 1, 3, true);
    defer heap.deinit();
    const sorted = heap.getSorted();

    try std.testing.expectEqual(@as(usize, 3), sorted.len);
    try std.testing.expectEqualStrings("4", sorted[0].row.get(0).?);
    try std.testing.expectEqualStrings("2", sorted[1].row.get(0).?);
    try std.testing.expectEqualStrings("3", sorted[2].row.get(0).?);
}

test "topk: ascending" {
    const allocator = std.testing.allocator;
    const path = "test_topk_asc.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n3,900\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    var heap = try topK(allocator, &q, 1, 2, false);
    defer heap.deinit();
    const sorted = heap.getSorted();

    try std.testing.expectEqual(@as(usize, 2), sorted.len);
    try std.testing.expectEqualStrings("1", sorted[0].row.get(0).?);
    try std.testing.expectEqualStrings("3", sorted[1].row.get(0).?);
}

test "topk: K larger than N returns all rows, sorted" {
    const allocator = std.testing.allocator;
    const path = "test_topk_k_gt_n.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{});
    defer q.deinit();

    var heap = try topK(allocator, &q, 1, 10, true);
    defer heap.deinit();
    try std.testing.expectEqual(@as(usize, 2), heap.getSorted().len);
}

test "topk: composes with WHERE" {
    const allocator = std.testing.allocator;
    const path = "test_topk_filtered.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,city,amount\n1,Austin,50\n2,Denver,3000\n3,Austin,1500\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    var q = try Query.open(allocator, path, .{ .where = &.{scan.Predicate.init(1, .eq, "Austin")} });
    defer q.deinit();

    var heap = try topK(allocator, &q, 2, 1, true);
    defer heap.deinit();
    const sorted = heap.getSorted();
    try std.testing.expectEqual(@as(usize, 1), sorted.len);
    try std.testing.expectEqualStrings("3", sorted[0].row.get(0).?);
}
