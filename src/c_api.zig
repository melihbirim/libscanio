//! C ABI — the one stable, minimal surface external bindings compile
//! against. Zig internals (Scanner, Query, Predicate) are never exposed
//! here directly; this file only translates between them and a plain C
//! shape.
//!
//! Allocator choice matters more than it looks: this library gets
//! dlopen()'d into a host process (Python via ctypes, Node via N-API) —
//! the exact shape that broke csvql's own node/Python bindings once
//! (issue #149, https://github.com/melihbirim/csvql/issues/149).
//! std.heap.GeneralPurposeAllocator's PageAllocator faults inside a
//! dlopen()ed .so; std.heap.c_allocator (real libc malloc) does not.
//! Every allocation in this file goes through c_allocator for that
//! reason — not out of habit.
const std = @import("std");
const scan = @import("scanio");
const Query = scan.Query;
const Predicate = scan.Predicate;
const Op = scan.Op;
const TopK = scan.TopK;

const c_allocator = std.heap.c_allocator;

threadlocal var last_error_buf: [512]u8 = undefined;
threadlocal var last_error: ?[]const u8 = null;

fn setError(comptime fmt: []const u8, args: anytype) void {
    last_error = std.fmt.bufPrint(&last_error_buf, fmt, args) catch "error (message too long)";
}

fn clearError() void {
    last_error = null;
}

export fn scanio_last_error() ?[*:0]const u8 {
    const msg = last_error orelse return null;
    // Re-render into a NUL-terminated copy on demand rather than keeping
    // every setError() call NUL-terminated up front.
    if (msg.len >= last_error_buf.len) return null;
    last_error_buf[msg.len] = 0;
    return @ptrCast(last_error_buf[0..msg.len :0].ptr);
}

const CPredicate = extern struct {
    column: usize,
    op: c_int,
    value: [*:0]const u8,
};

const COptions = extern struct {
    columns: ?[*]const usize,
    n_columns: usize,
    where: ?[*]const CPredicate,
    n_where: usize,
    limit: i64,
};

/// Owns everything needed to answer scanio_next()/scanio_count() calls:
/// the Query itself, plus the reusable NUL-terminated-copy buffers a C
/// caller needs (the Zig core stays zero-copy internally; only this
/// boundary pays the cost of NUL-terminating each field for C strings).
const Ctx = struct {
    query: Query,
    predicates: []Predicate,
    /// One owned NUL-terminated copy per field, reused/grown across next()
    /// calls. Plain []u8, not [:0]u8 — the NUL byte is placed manually at
    /// field.len and the pointer handed to C is cast at the call site;
    /// tracking the sentinel at the type level buys nothing here and
    /// makes the reused-buffer growth logic awkward.
    field_cstrs: [][]u8 = &.{},
    /// Pointer array handed back to the caller as `const char **`.
    field_ptrs: [][*:0]const u8 = &.{},
    /// NUL-terminated header column names, built once at open() — small
    /// and fixed-size, unlike row fields, so no reuse/grow logic needed.
    header_cstrs: [][:0]u8 = &.{},

    fn ensureFieldCapacity(self: *Ctx, n: usize) void {
        if (n <= self.field_cstrs.len) return;
        const old_len = self.field_cstrs.len;
        const grown_cstrs = c_allocator.realloc(self.field_cstrs, n) catch return;
        self.field_cstrs = grown_cstrs;
        for (self.field_cstrs[old_len..]) |*slot| slot.* = &.{};
        const grown_ptrs = c_allocator.realloc(self.field_ptrs, n) catch return;
        self.field_ptrs = grown_ptrs;
    }
};

export fn scanio_open(path: ?[*:0]const u8, options: ?*const COptions) ?*Ctx {
    clearError();
    const p = path orelse {
        setError("path is null", .{});
        return null;
    };

    var predicates: []Predicate = &.{};
    var columns: ?[]const usize = null;
    var limit: ?usize = null;

    if (options) |o| {
        if (o.n_where > 0) {
            const cpreds = o.where.?[0..o.n_where];
            predicates = c_allocator.alloc(Predicate, cpreds.len) catch {
                setError("out of memory allocating predicates", .{});
                return null;
            };
            for (cpreds, 0..) |cp, i| {
                const op: Op = switch (cp.op) {
                    0 => .eq,
                    1 => .neq,
                    2 => .gt,
                    3 => .gte,
                    4 => .lt,
                    5 => .lte,
                    else => .eq,
                };
                predicates[i] = Predicate.init(cp.column, op, std.mem.span(cp.value));
            }
        }
        if (o.n_columns > 0) columns = o.columns.?[0..o.n_columns];
        if (o.limit >= 0) limit = @intCast(o.limit);
    }

    const ctx = c_allocator.create(Ctx) catch {
        setError("out of memory allocating scanner context", .{});
        return null;
    };
    ctx.* = .{
        .query = Query.open(c_allocator, std.mem.span(p), .{
            .columns = columns,
            .where = predicates,
            .limit = limit,
        }) catch |e| {
            setError("open failed: {s}", .{@errorName(e)});
            c_allocator.destroy(ctx);
            if (predicates.len > 0) c_allocator.free(predicates);
            return null;
        },
        .predicates = predicates,
    };

    const header = ctx.query.header();
    ctx.header_cstrs = c_allocator.alloc([:0]u8, header.len) catch {
        setError("out of memory allocating header", .{});
        ctx.query.deinit();
        c_allocator.destroy(ctx);
        if (predicates.len > 0) c_allocator.free(predicates);
        return null;
    };
    for (header, 0..) |name, i| {
        ctx.header_cstrs[i] = c_allocator.allocSentinel(u8, name.len, 0) catch {
            setError("out of memory allocating header", .{});
            return null; // ctx now partially initialized; leaked on this rare OOM path, not worth the extra bookkeeping.
        };
        @memcpy(ctx.header_cstrs[i], name);
    }
    return ctx;
}

export fn scanio_column_index(ctx: ?*Ctx, name: ?[*:0]const u8) usize {
    const c = ctx orelse return std.math.maxInt(usize);
    const n = name orelse return std.math.maxInt(usize);
    return c.query.columnIndex(std.mem.span(n)) orelse std.math.maxInt(usize);
}

/// Number of columns in the header.
export fn scanio_n_columns(ctx: ?*Ctx) usize {
    const c = ctx orelse return 0;
    return c.header_cstrs.len;
}

/// Column name at `index`, or NULL if out of range.
export fn scanio_column_name(ctx: ?*Ctx, index: usize) ?[*:0]const u8 {
    const c = ctx orelse return null;
    if (index >= c.header_cstrs.len) return null;
    return c.header_cstrs[index].ptr;
}

export fn scanio_next(ctx: ?*Ctx, out_fields: ?*[*]const [*:0]const u8, out_n: ?*usize) c_int {
    clearError();
    const c = ctx orelse {
        setError("scanner is null", .{});
        return -1;
    };
    const row = c.query.next() catch |e| {
        setError("next failed: {s}", .{@errorName(e)});
        return -1;
    } orelse return 0;

    c.ensureFieldCapacity(row.fields.len);
    for (row.fields, 0..) |field, i| {
        if (c.field_cstrs[i].len < field.len + 1) {
            const grown = c_allocator.realloc(c.field_cstrs[i], field.len + 1) catch {
                setError("out of memory copying row", .{});
                return -1;
            };
            c.field_cstrs[i] = grown;
        }
        @memcpy(c.field_cstrs[i][0..field.len], field);
        c.field_cstrs[i][field.len] = 0;
        c.field_ptrs[i] = @ptrCast(c.field_cstrs[i].ptr);
    }

    if (out_fields) |of| of.* = c.field_ptrs.ptr;
    if (out_n) |on| on.* = row.fields.len;
    return 1;
}

export fn scanio_count(ctx: ?*Ctx) i64 {
    clearError();
    const c = ctx orelse {
        setError("scanner is null", .{});
        return -1;
    };
    const n = c.query.count() catch |e| {
        setError("count failed: {s}", .{@errorName(e)});
        return -1;
    };
    return @intCast(n);
}

const AggC = extern struct {
    count: u64,
    sum: f64,
    min: f64,
    max: f64,
    avg: f64,
    /// count == 0 means min/max/avg above are meaningless (no numeric
    /// values seen) — ctypes has no natural "optional f64", so this is
    /// the caller's signal to check before trusting them, same shape as
    /// AggResult.avg()'s ?f64 in the Zig API.
    has_values: c_int,
};

/// Aggregate count/sum/min/max/avg over `column` for the REST of the rows
/// this ctx has left to yield — same "drains the query" semantics as
/// scanio_count(). Composes with whatever WHERE/columns/limit the ctx was
/// opened with, same as the Zig aggregate() function it wraps.
export fn scanio_aggregate(ctx: ?*Ctx, column: usize, out: ?*AggC) c_int {
    clearError();
    const c = ctx orelse {
        setError("scanner is null", .{});
        return -1;
    };
    const o = out orelse {
        setError("output pointer is null", .{});
        return -1;
    };
    const r = scan.aggregate(&c.query, column) catch |e| {
        setError("aggregate failed: {s}", .{@errorName(e)});
        return -1;
    };
    o.* = .{
        .count = r.count,
        .sum = r.sum,
        .min = r.min orelse 0,
        .max = r.max orelse 0,
        .avg = r.avg() orelse 0,
        .has_values = if (r.count > 0) 1 else 0,
    };
    return 0;
}

/// Owns a completed top-K result plus the reusable NUL-terminated-copy
/// buffers scanio_topk_next() hands back, same shape as Ctx's field_cstrs.
const TopkCtx = struct {
    topk: TopK,
    sorted: []scan.Entry = &.{},
    index: usize = 0,
    field_cstrs: [][]u8 = &.{},
    field_ptrs: [][*:0]const u8 = &.{},

    fn ensureFieldCapacity(self: *TopkCtx, n: usize) void {
        if (n <= self.field_cstrs.len) return;
        const old_len = self.field_cstrs.len;
        const grown_cstrs = c_allocator.realloc(self.field_cstrs, n) catch return;
        self.field_cstrs = grown_cstrs;
        for (self.field_cstrs[old_len..]) |*slot| slot.* = &.{};
        const grown_ptrs = c_allocator.realloc(self.field_ptrs, n) catch return;
        self.field_ptrs = grown_ptrs;
    }
};

/// Runs top-K over the REST of ctx's rows (same drains-the-query
/// semantics as scanio_count()/scanio_aggregate()) and returns a handle
/// to walk the K results via scanio_topk_next(). ctx itself is left
/// exhausted but still valid to scanio_close() normally afterward.
export fn scanio_topk(ctx: ?*Ctx, column: usize, k: usize, descending: c_int) ?*TopkCtx {
    clearError();
    const c = ctx orelse {
        setError("scanner is null", .{});
        return null;
    };
    var heap = scan.topK(c_allocator, &c.query, column, k, descending != 0) catch |e| {
        setError("topk failed: {s}", .{@errorName(e)});
        return null;
    };
    const tctx = c_allocator.create(TopkCtx) catch {
        heap.deinit();
        setError("out of memory allocating topk context", .{});
        return null;
    };
    tctx.* = .{ .topk = heap };
    tctx.sorted = tctx.topk.getSorted();
    return tctx;
}

/// Walks the sorted top-K results, best-to-worst, one at a time — same
/// call shape as scanio_next(): 1 = row filled in, 0 = exhausted, -1 =
/// error. out_key receives that row's sort key (the numeric value of the
/// column top-K was run on).
export fn scanio_topk_next(tctx: ?*TopkCtx, out_fields: ?*[*]const [*:0]const u8, out_n: ?*usize, out_key: ?*f64) c_int {
    clearError();
    const t = tctx orelse {
        setError("topk context is null", .{});
        return -1;
    };
    if (t.index >= t.sorted.len) return 0;
    const entry = t.sorted[t.index];
    t.index += 1;

    t.ensureFieldCapacity(entry.row.fields.len);
    for (entry.row.fields, 0..) |field, i| {
        if (t.field_cstrs[i].len < field.len + 1) {
            const grown = c_allocator.realloc(t.field_cstrs[i], field.len + 1) catch {
                setError("out of memory copying row", .{});
                return -1;
            };
            t.field_cstrs[i] = grown;
        }
        @memcpy(t.field_cstrs[i][0..field.len], field);
        t.field_cstrs[i][field.len] = 0;
        t.field_ptrs[i] = @ptrCast(t.field_cstrs[i].ptr);
    }

    if (out_fields) |of| of.* = t.field_ptrs.ptr;
    if (out_n) |on| on.* = entry.row.fields.len;
    if (out_key) |ok| ok.* = entry.key;
    return 1;
}

export fn scanio_topk_close(tctx: ?*TopkCtx) void {
    const t = tctx orelse return;
    t.topk.deinit();
    for (t.field_cstrs) |buf| {
        if (buf.len > 0) c_allocator.free(buf);
    }
    if (t.field_cstrs.len > 0) c_allocator.free(t.field_cstrs);
    if (t.field_ptrs.len > 0) c_allocator.free(t.field_ptrs);
    c_allocator.destroy(t);
}

export fn scanio_close(ctx: ?*Ctx) void {
    const c = ctx orelse return;
    c.query.deinit();
    for (c.field_cstrs) |buf| {
        if (buf.len > 0) c_allocator.free(buf);
    }
    if (c.field_cstrs.len > 0) c_allocator.free(c.field_cstrs);
    if (c.field_ptrs.len > 0) c_allocator.free(c.field_ptrs);
    if (c.predicates.len > 0) c_allocator.free(c.predicates);
    for (c.header_cstrs) |buf| c_allocator.free(buf);
    if (c.header_cstrs.len > 0) c_allocator.free(c.header_cstrs);
    c_allocator.destroy(c);
}

test "C ABI: open, next, close on a simple file" {
    const path = "test_c_api.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctx = scanio_open(path, null);
    try std.testing.expect(ctx != null);
    defer scanio_close(ctx);

    var fields: [*]const [*:0]const u8 = undefined;
    var n: usize = 0;
    const rc1 = scanio_next(ctx, &fields, &n);
    try std.testing.expectEqual(@as(c_int, 1), rc1);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("1", std.mem.span(fields[0]));
    try std.testing.expectEqualStrings("50", std.mem.span(fields[1]));

    const rc2 = scanio_next(ctx, &fields, &n);
    try std.testing.expectEqual(@as(c_int, 1), rc2);
    try std.testing.expectEqualStrings("2", std.mem.span(fields[0]));

    const rc3 = scanio_next(ctx, &fields, &n);
    try std.testing.expectEqual(@as(c_int, 0), rc3);
}

test "C ABI: open with a filter predicate and a limit" {
    const path = "test_c_api_filter.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n3,2500\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const preds = [_]CPredicate{.{ .column = 1, .op = 2, .value = "1000" }};
    const opts = COptions{
        .columns = null,
        .n_columns = 0,
        .where = &preds,
        .n_where = 1,
        .limit = 1,
    };
    const ctx = scanio_open(path, &opts);
    try std.testing.expect(ctx != null);
    defer scanio_close(ctx);

    var fields: [*]const [*:0]const u8 = undefined;
    var n: usize = 0;
    try std.testing.expectEqual(@as(c_int, 1), scanio_next(ctx, &fields, &n));
    try std.testing.expectEqualStrings("2", std.mem.span(fields[0]));
    // limit=1: no second row even though row 3 also matches the filter.
    try std.testing.expectEqual(@as(c_int, 0), scanio_next(ctx, &fields, &n));
}

test "C ABI: scanio_open returns null and sets an error for a missing file" {
    const ctx = scanio_open("test_c_api_does_not_exist.csv", null);
    try std.testing.expect(ctx == null);
    try std.testing.expect(scanio_last_error() != null);
}

test "C ABI: scanio_count fast path" {
    const path = "test_c_api_count.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id\n1\n2\n3\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctx = scanio_open(path, null);
    defer scanio_close(ctx);
    try std.testing.expectEqual(@as(i64, 3), scanio_count(ctx));
}

test "C ABI: scanio_column_index" {
    const path = "test_c_api_colidx.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,name\n1,Alice\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctx = scanio_open(path, null);
    defer scanio_close(ctx);
    try std.testing.expectEqual(@as(usize, 1), scanio_column_index(ctx, "name"));
    try std.testing.expectEqual(std.math.maxInt(usize), scanio_column_index(ctx, "nope"));
}

test "C ABI: scanio_n_columns and scanio_column_name" {
    const path = "test_c_api_header.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,name,amount\n1,Alice,50\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctx = scanio_open(path, null);
    defer scanio_close(ctx);
    try std.testing.expectEqual(@as(usize, 3), scanio_n_columns(ctx));
    try std.testing.expectEqualStrings("id", std.mem.span(scanio_column_name(ctx, 0).?));
    try std.testing.expectEqualStrings("name", std.mem.span(scanio_column_name(ctx, 1).?));
    try std.testing.expectEqualStrings("amount", std.mem.span(scanio_column_name(ctx, 2).?));
    try std.testing.expect(scanio_column_name(ctx, 3) == null);
}

test "C ABI: scanio_aggregate over a numeric column" {
    const path = "test_c_api_aggregate.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n3,900\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctx = scanio_open(path, null);
    defer scanio_close(ctx);

    var out: AggC = undefined;
    try std.testing.expectEqual(@as(c_int, 0), scanio_aggregate(ctx, 1, &out));
    try std.testing.expectEqual(@as(u64, 3), out.count);
    try std.testing.expectEqual(@as(f64, 2450), out.sum);
    try std.testing.expectEqual(@as(f64, 50), out.min);
    try std.testing.expectEqual(@as(f64, 1500), out.max);
    try std.testing.expectApproxEqAbs(@as(f64, 2450.0 / 3.0), out.avg, 0.0001);
    try std.testing.expectEqual(@as(c_int, 1), out.has_values);
}

test "C ABI: scanio_aggregate on an empty result sets has_values = 0" {
    const path = "test_c_api_aggregate_empty.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,notanumber\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctx = scanio_open(path, null);
    defer scanio_close(ctx);

    var out: AggC = undefined;
    try std.testing.expectEqual(@as(c_int, 0), scanio_aggregate(ctx, 1, &out));
    try std.testing.expectEqual(@as(c_int, 0), out.has_values);
}

test "C ABI: scanio_topk walks results best-to-worst" {
    const path = "test_c_api_topk.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n3,900\n4,3000\n5,200\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctx = scanio_open(path, null);
    defer scanio_close(ctx);

    const tctx = scanio_topk(ctx, 1, 3, 1); // descending
    try std.testing.expect(tctx != null);
    defer scanio_topk_close(tctx);

    var fields: [*]const [*:0]const u8 = undefined;
    var n: usize = 0;
    var key: f64 = 0;

    try std.testing.expectEqual(@as(c_int, 1), scanio_topk_next(tctx, &fields, &n, &key));
    try std.testing.expectEqualStrings("4", std.mem.span(fields[0]));
    try std.testing.expectEqual(@as(f64, 3000), key);

    try std.testing.expectEqual(@as(c_int, 1), scanio_topk_next(tctx, &fields, &n, &key));
    try std.testing.expectEqualStrings("2", std.mem.span(fields[0]));
    try std.testing.expectEqual(@as(f64, 1500), key);

    try std.testing.expectEqual(@as(c_int, 1), scanio_topk_next(tctx, &fields, &n, &key));
    try std.testing.expectEqualStrings("3", std.mem.span(fields[0]));

    try std.testing.expectEqual(@as(c_int, 0), scanio_topk_next(tctx, &fields, &n, &key));
}

test "C ABI: scanio_topk composes with a WHERE-filtered ctx" {
    const path = "test_c_api_topk_filtered.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,city,amount\n1,Austin,50\n2,Denver,3000\n3,Austin,1500\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const preds = [_]CPredicate{.{ .column = 1, .op = 0, .value = "Austin" }};
    const opts = COptions{ .columns = null, .n_columns = 0, .where = &preds, .n_where = 1, .limit = -1 };
    const ctx = scanio_open(path, &opts);
    defer scanio_close(ctx);

    const tctx = scanio_topk(ctx, 2, 1, 1);
    defer scanio_topk_close(tctx);

    var fields: [*]const [*:0]const u8 = undefined;
    var n: usize = 0;
    var key: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 1), scanio_topk_next(tctx, &fields, &n, &key));
    try std.testing.expectEqualStrings("3", std.mem.span(fields[0]));
    try std.testing.expectEqual(@as(c_int, 0), scanio_topk_next(tctx, &fields, &n, &key));
}
