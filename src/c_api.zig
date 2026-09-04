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

// NOT threadlocal, on purpose — real, reproduced bug, not a hypothetical
// one: `threadlocal` here SIGSEGV'd on Linux inside the real dlopen()
// smoke test (Python ctypes.CDLL(), the actual consumer path), zero
// output before the crash. This is a known class of issue independent
// of Zig — a shared library loaded via dlopen() at RUNTIME (not linked
// at program startup) generally needs the "general dynamic" TLS model;
// Zig's default model on Linux assumes "initial exec" (library present
// at process startup), which SIGSEGVs when that assumption is false.
// Same root cause as a documented RedHat KB issue for dlopen()+TLS in
// general, not Zig-specific. Traded real thread-safety for
// scanio_last_error() specifically (a race between threads could see
// the wrong thread's error message) for the library actually working
// when dlopen()'d — the scan operations themselves don't touch this
// state, only the diagnostic error-message path does.
var last_error_buf: [512]u8 = undefined;
var last_error: ?[]const u8 = null;

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
    /// Used for every op except IN (op == 6) — IN uses `values`/`n_values`
    /// instead. Still required to be a valid NUL-terminated string even
    /// for IN predicates (it's simply not read); pass "" from the caller.
    value: [*:0]const u8,
    /// Only used when op == 6 (IN). Nullable/0 otherwise.
    values: ?[*]const [*:0]const u8 = null,
    n_values: usize = 0,
};

const COptions = extern struct {
    columns: ?[*]const usize,
    n_columns: usize,
    where: ?[*]const CPredicate,
    n_where: usize,
    limit: i64,
    /// Highest column index the caller will ever read from this scan
    /// (max of every WHERE predicate's column, every projected column,
    /// and — for count()/aggregate()/topk() callers, which don't use
    /// `columns` at all — whatever single column they read). -1 = don't
    /// know / need every column, splits every field (safe default,
    /// same behavior as before this field existed). Set this whenever
    /// the caller genuinely knows the bound — real, measured win: up to
    /// 3.6x faster on a low-selectivity WHERE over an early column (see
    /// ROADMAP.md), since trailing unneeded fields are never scanned at
    /// all rather than split-then-discarded.
    max_column: i64 = -1,
};

/// Owns everything needed to answer scanio_next()/scanio_count() calls:
/// the Query itself, plus the reusable NUL-terminated-copy buffers a C
/// caller needs (the Zig core stays zero-copy internally; only this
/// boundary pays the cost of NUL-terminating each field for C strings).
const Ctx = struct {
    query: Query,
    predicates: []Predicate,
    /// Parallel to `predicates` — each entry is that predicate's owned IN
    /// value set (empty slice for every non-IN predicate). Owns both the
    /// per-value string copies and the slice holding them; freed in
    /// scanio_close().
    in_values: [][]const []const u8 = &.{},
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
    var in_values: [][]const []const u8 = &.{};
    var columns: ?[]const usize = null;
    var limit: ?usize = null;

    if (options) |o| {
        if (o.n_where > 0) {
            const cpreds = o.where.?[0..o.n_where];
            predicates = c_allocator.alloc(Predicate, cpreds.len) catch {
                setError("out of memory allocating predicates", .{});
                return null;
            };
            in_values = c_allocator.alloc([]const []const u8, cpreds.len) catch {
                setError("out of memory allocating predicates", .{});
                c_allocator.free(predicates);
                return null;
            };
            @memset(in_values, &.{});
            for (cpreds, 0..) |cp, i| {
                if (cp.op == 6) {
                    const cvals = cp.values.?[0..cp.n_values];
                    const owned = c_allocator.alloc([]const u8, cvals.len) catch {
                        setError("out of memory allocating IN values", .{});
                        return null;
                    };
                    for (cvals, 0..) |cv, j| {
                        owned[j] = c_allocator.dupe(u8, std.mem.span(cv)) catch {
                            setError("out of memory allocating IN values", .{});
                            return null;
                        };
                    }
                    in_values[i] = owned;
                    predicates[i] = Predicate.initIn(cp.column, owned);
                    continue;
                }
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

    const stop_after_column: ?usize = if (options) |o| (if (o.max_column >= 0) @intCast(o.max_column) else null) else null;

    const ctx = c_allocator.create(Ctx) catch {
        setError("out of memory allocating scanner context", .{});
        return null;
    };
    ctx.* = .{
        .query = Query.open(c_allocator, std.mem.span(p), .{
            .columns = columns,
            .where = predicates,
            .limit = limit,
            .stop_after_column = stop_after_column,
        }) catch |e| {
            setError("open failed: {s}", .{@errorName(e)});
            c_allocator.destroy(ctx);
            if (predicates.len > 0) c_allocator.free(predicates);
            return null;
        },
        .predicates = predicates,
        .in_values = in_values,
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

/// Owns a completed ORDER BY result plus the reusable NUL-terminated-copy
/// buffers scanio_order_by_next() hands back — same shape as TopkCtx
/// above, minus the sort key (ORDER BY has no separate "key" concept
/// exposed to the caller the way top-K's ranking value is).
const OrderByCtx = struct {
    result: scan.OrderedRows,
    index: usize = 0,
    field_cstrs: [][]u8 = &.{},
    field_ptrs: [][*:0]const u8 = &.{},

    fn ensureFieldCapacity(self: *OrderByCtx, n: usize) void {
        if (n <= self.field_cstrs.len) return;
        const old_len = self.field_cstrs.len;
        const grown_cstrs = c_allocator.realloc(self.field_cstrs, n) catch return;
        self.field_cstrs = grown_cstrs;
        for (self.field_cstrs[old_len..]) |*slot| slot.* = &.{};
        const grown_ptrs = c_allocator.realloc(self.field_ptrs, n) catch return;
        self.field_ptrs = grown_ptrs;
    }
};

/// Runs ORDER BY over the REST of ctx's rows (same drains-the-query
/// semantics as scanio_topk()/scanio_count()) and returns a handle to
/// walk the sorted results via scanio_order_by_next(). Materializes
/// every matching row before sorting — see order.zig's doc comment for
/// why (peak memory scales with the filtered row count, not the file
/// size — the same tradeoff scanio_topk()/scanio_aggregate() already
/// accept, not a new one introduced here).
export fn scanio_order_by(ctx: ?*Ctx, column: usize, descending: c_int) ?*OrderByCtx {
    clearError();
    const c = ctx orelse {
        setError("scanner is null", .{});
        return null;
    };
    const result = scan.orderBy(c_allocator, &c.query, column, descending != 0) catch |e| {
        setError("order_by failed: {s}", .{@errorName(e)});
        return null;
    };
    const octx = c_allocator.create(OrderByCtx) catch {
        var r = result;
        r.deinit();
        setError("out of memory allocating order_by context", .{});
        return null;
    };
    octx.* = .{ .result = result };
    return octx;
}

/// Walks the sorted results, one row at a time — same call shape as
/// scanio_next()/scanio_topk_next(): 1 = row filled in, 0 = exhausted,
/// -1 = error.
export fn scanio_order_by_next(octx: ?*OrderByCtx, out_fields: ?*[*]const [*:0]const u8, out_n: ?*usize) c_int {
    clearError();
    const o = octx orelse {
        setError("order_by context is null", .{});
        return -1;
    };
    if (o.index >= o.result.rows.len) return 0;
    const row = o.result.rows[o.index];
    o.index += 1;

    o.ensureFieldCapacity(row.fields.len);
    for (row.fields, 0..) |field, i| {
        if (o.field_cstrs[i].len < field.len + 1) {
            const grown = c_allocator.realloc(o.field_cstrs[i], field.len + 1) catch {
                setError("out of memory copying row", .{});
                return -1;
            };
            o.field_cstrs[i] = grown;
        }
        @memcpy(o.field_cstrs[i][0..field.len], field);
        o.field_cstrs[i][field.len] = 0;
        o.field_ptrs[i] = @ptrCast(o.field_cstrs[i].ptr);
    }

    if (out_fields) |of| of.* = o.field_ptrs.ptr;
    if (out_n) |on| on.* = row.fields.len;
    return 1;
}

export fn scanio_order_by_close(octx: ?*OrderByCtx) void {
    const o = octx orelse return;
    o.result.deinit();
    for (o.field_cstrs) |buf| {
        if (buf.len > 0) c_allocator.free(buf);
    }
    if (o.field_cstrs.len > 0) c_allocator.free(o.field_cstrs);
    if (o.field_ptrs.len > 0) c_allocator.free(o.field_ptrs);
    c_allocator.destroy(o);
}

/// Owns a bulk-collected scan result: every matching row's fields,
/// NUL-separated, row-major, in one contiguous buffer. Exists to let a
/// caller (Python via ctypes) fetch the WHOLE result in a single bulk
/// copy instead of one small FFI call per field per row — that per-call
/// crossing cost, not the scan itself, dominates when a caller wants
/// every matching row back as real objects. Measured on a 417MB/1M-row
/// file: row-at-a-time scanio_next() + per-field decode() from Python
/// took ~4.8s for ~967K matching rows (2 projected columns); this path
/// is the fix for that, not a micro-optimization of it.
const CollectCtx = struct {
    buf: std.ArrayListUnmanaged(u8) = .{},
    n_rows: usize = 0,
    n_cols: usize = 0,
};

/// Runs the REST of ctx's rows to completion (drains it, same semantics
/// as scanio_count()/scanio_aggregate()/scanio_topk()) and packs every
/// matching row's fields into one buffer, NUL-separated, row-major.
/// Returns NULL on error — call scanio_last_error().
export fn scanio_collect(ctx: ?*Ctx) ?*CollectCtx {
    clearError();
    const c = ctx orelse {
        setError("scanner is null", .{});
        return null;
    };
    const cc = c_allocator.create(CollectCtx) catch {
        setError("out of memory allocating collect context", .{});
        return null;
    };
    cc.* = .{};
    while (true) {
        const row = c.query.next() catch |e| {
            setError("collect failed: {s}", .{@errorName(e)});
            cc.buf.deinit(c_allocator);
            c_allocator.destroy(cc);
            return null;
        } orelse break;
        if (cc.n_rows == 0) cc.n_cols = row.fields.len;
        for (row.fields) |field| {
            cc.buf.appendSlice(c_allocator, field) catch {
                setError("out of memory collecting rows", .{});
                cc.buf.deinit(c_allocator);
                c_allocator.destroy(cc);
                return null;
            };
            cc.buf.append(c_allocator, 0) catch {
                setError("out of memory collecting rows", .{});
                cc.buf.deinit(c_allocator);
                c_allocator.destroy(cc);
                return null;
            };
        }
        cc.n_rows += 1;
    }
    return cc;
}

/// Pointer to the packed buffer plus its length. The pointer is valid
/// until scanio_collect_close(); the caller (Python) should copy it out
/// immediately (e.g. ctypes.string_at) rather than hold the pointer.
export fn scanio_collect_data(cc: ?*CollectCtx, out_len: ?*usize) ?[*]const u8 {
    const c = cc orelse return null;
    if (out_len) |ol| ol.* = c.buf.items.len;
    if (c.buf.items.len == 0) return null;
    return c.buf.items.ptr;
}

export fn scanio_collect_n_rows(cc: ?*CollectCtx) usize {
    const c = cc orelse return 0;
    return c.n_rows;
}

export fn scanio_collect_n_cols(cc: ?*CollectCtx) usize {
    const c = cc orelse return 0;
    return c.n_cols;
}

export fn scanio_collect_close(cc: ?*CollectCtx) void {
    const c = cc orelse return;
    c.buf.deinit(c_allocator);
    c_allocator.destroy(c);
}

/// COLUMNAR collection — the real fix for scan_array()/scanArray()'s
/// concurrent-memory problem (see ROADMAP.md), not scanio_collect()
/// above (which was already close to optimal for its own row-major NUL-
/// separated shape — measured, not assumed, via a two-pass exact-sizing
/// rewrite of a standalone bench tool that barely moved the needle).
/// The real, unfixable-from-the-Zig-side cost was downstream: Python
/// building one dict + N string objects per row pays real, inherent
/// CPython object overhead (~124 bytes/row measured on a real 10-column
/// fixture) no matter how efficiently the Zig side packs bytes for it.
///
/// This is the actual fix: pack data COLUMN-major instead of row-major,
/// in exactly the layout Apache Arrow's StringArray already uses (a
/// concatenated data buffer + a `u32` offsets array, offsets[i] marking
/// where row i's value starts, one accessor pair per column) — so a
/// caller with pyarrow available can build a `pa.Table` via
/// `pa.StringArray.from_buffers()` with ZERO Python object construction
/// per cell, only lightweight Arrow array wrappers over the SAME memory
/// this function already allocated. No NUL terminators needed either
/// (Arrow uses offsets, not termination) — one byte/field leaner than
/// scanio_collect()'s format too.
/// Same type parallel.zig's parallelScanColumnar()/mergeColumnarWorkers()
/// use — aliased, not redefined, so scanio_parallel_collect_columnar()
/// below can wrap that function's output DIRECTLY with zero re-copy,
/// which was the whole point of unifying the two. offsets.items.len ==
/// n_rows + 1 always; offsets[0] == 0; offsets[i] is the END (exclusive)
/// byte position of row i-1's value in `data` — i.e. row i's value is
/// data[offsets[i]..offsets[i+1]].
const ColumnBuf = scan.ColumnBuf;

const CollectColumnarCtx = struct {
    columns: []ColumnBuf = &.{},
    n_rows: usize = 0,
    n_cols: usize = 0,

    fn deinitAndFree(self: *CollectColumnarCtx) void {
        for (self.columns) |*col| col.deinit(c_allocator);
        if (self.columns.len > 0) c_allocator.free(self.columns);
    }
};

fn appendColumnarRow(columns: []ColumnBuf, row: scan.Row) !void {
    for (row.fields, 0..) |field, i| {
        try columns[i].data.appendSlice(c_allocator, field);
        try columns[i].offsets.append(c_allocator, @intCast(columns[i].data.items.len));
    }
}

/// Runs the REST of ctx's rows to completion (same drain semantics as
/// scanio_collect()) into the columnar layout described above. Returns
/// NULL on error — call scanio_last_error().
export fn scanio_collect_columnar(ctx: ?*Ctx) ?*CollectColumnarCtx {
    clearError();
    const c = ctx orelse {
        setError("scanner is null", .{});
        return null;
    };
    const cc = c_allocator.create(CollectColumnarCtx) catch {
        setError("out of memory allocating columnar collect context", .{});
        return null;
    };
    cc.* = .{};

    const first_row = c.query.next() catch |e| {
        setError("collect failed: {s}", .{@errorName(e)});
        c_allocator.destroy(cc);
        return null;
    } orelse return cc; // zero matching rows — n_rows=0, n_cols=0, still a valid handle

    cc.n_cols = first_row.fields.len;
    cc.columns = c_allocator.alloc(ColumnBuf, cc.n_cols) catch {
        setError("out of memory allocating columnar collect context", .{});
        c_allocator.destroy(cc);
        return null;
    };
    for (cc.columns) |*col| col.* = .{};
    for (cc.columns) |*col| col.offsets.append(c_allocator, 0) catch {
        setError("out of memory allocating columnar collect context", .{});
        cc.deinitAndFree();
        c_allocator.destroy(cc);
        return null;
    };

    appendColumnarRow(cc.columns, first_row) catch {
        setError("out of memory collecting rows", .{});
        cc.deinitAndFree();
        c_allocator.destroy(cc);
        return null;
    };
    cc.n_rows = 1;

    while (true) {
        const row = c.query.next() catch |e| {
            setError("collect failed: {s}", .{@errorName(e)});
            cc.deinitAndFree();
            c_allocator.destroy(cc);
            return null;
        } orelse break;
        appendColumnarRow(cc.columns, row) catch {
            setError("out of memory collecting rows", .{});
            cc.deinitAndFree();
            c_allocator.destroy(cc);
            return null;
        };
        cc.n_rows += 1;
    }
    return cc;
}

export fn scanio_collect_columnar_n_rows(cc: ?*CollectColumnarCtx) usize {
    const c = cc orelse return 0;
    return c.n_rows;
}

export fn scanio_collect_columnar_n_cols(cc: ?*CollectColumnarCtx) usize {
    const c = cc orelse return 0;
    return c.n_cols;
}

/// Column `col_idx`'s concatenated value bytes. `out_len` receives the
/// byte length of the WHOLE buffer (not one row) — a caller reconstructs
/// individual values via the offsets array from
/// scanio_collect_columnar_offsets(). Pointer valid until
/// scanio_collect_columnar_close(); mirrors scanio_collect_data()'s own
/// "copy it out or wrap it zero-copy immediately" contract.
export fn scanio_collect_columnar_data(cc: ?*CollectColumnarCtx, col_idx: usize, out_len: ?*usize) ?[*]const u8 {
    const c = cc orelse return null;
    if (col_idx >= c.columns.len) return null;
    const col = &c.columns[col_idx];
    if (out_len) |ol| ol.* = col.data.items.len;
    if (col.data.items.len == 0) return null;
    return col.data.items.ptr;
}

/// Column `col_idx`'s offsets array — `n_rows + 1` entries, `u32`,
/// offsets[0] == 0, row i's value is `data[offsets[i]..offsets[i+1]]`.
/// Exactly Apache Arrow's own StringArray offset-buffer format, on
/// purpose — a caller with pyarrow can wrap this directly via
/// `pa.StringArray.from_buffers()`, zero-copy.
export fn scanio_collect_columnar_offsets(cc: ?*CollectColumnarCtx, col_idx: usize, out_len: ?*usize) ?[*]const u32 {
    const c = cc orelse return null;
    if (col_idx >= c.columns.len) return null;
    const col = &c.columns[col_idx];
    if (out_len) |ol| ol.* = col.offsets.items.len;
    if (col.offsets.items.len == 0) return null;
    return col.offsets.items.ptr;
}

export fn scanio_collect_columnar_close(cc: ?*CollectColumnarCtx) void {
    const c = cc orelse return;
    c.deinitAndFree();
    c_allocator.destroy(c);
}

/// Multi-threaded materialized scan, same columnar output shape as
/// scanio_collect_columnar() above — the real fix for scan_array()/
/// scanArray()'s concurrent-memory problem (ROADMAP.md), not a
/// standalone bench tool: scanio_collect_columnar() drains a single-
/// threaded Ctx/Query one row at a time; this drives scan.parallelScan()
/// instead (the same multi-threaded engine M9's parallelCountRowsWhere/
/// parallelCountRows already use), then repacks its OwnedRow results
/// into the identical (data, offsets) columnar layout so a Python caller
/// doesn't need two different unpacking code paths depending on which
/// collector produced the result.
///
/// Takes path/predicates/delimiter directly (no `Ctx` — parallelScan
/// owns its own file access, doesn't compose with an already-open
/// single-threaded scanio_open() handle the way scanio_collect() does).
/// `num_threads` == 0 means "use std.Thread.getCpuCount()", matching
/// every other parallel_mod entry point's convention.
///
/// Known remaining inefficiency, not hidden: this copies each field
/// TWICE — once into parallelScan's OwnedRow (duplicated so it survives
/// each worker's reused scan buffer), once again into this function's
/// columnar buffers. Correct and still dramatically faster/leaner than
/// the single-threaded path it replaces (measured: 15-895MB / 0.05-0.47s
/// across N=1-32 concurrent processes vs duckdb's 75-1758MB / 0.66-0.89s
/// on the same real fixture — see ROADMAP.md) — but a further win is
/// available by having parallelScan's workers write directly into
/// per-column buffers instead of OwnedRow, skipping the double copy.
/// Not done here; this ships the real multi-threading win first.
export fn scanio_parallel_collect_columnar(
    path: ?[*:0]const u8,
    delimiter: u8,
    where: ?[*]const CPredicate,
    n_where: usize,
    num_threads: usize,
) ?*CollectColumnarCtx {
    clearError();
    const p = path orelse {
        setError("path is null", .{});
        return null;
    };

    var predicates: []Predicate = &.{};
    defer if (predicates.len > 0) c_allocator.free(predicates);
    var in_owned: [][]const []const u8 = &.{};
    defer {
        for (in_owned) |vals| {
            for (vals) |v| c_allocator.free(@constCast(v));
            if (vals.len > 0) c_allocator.free(@constCast(vals));
        }
        if (in_owned.len > 0) c_allocator.free(in_owned);
    }

    if (n_where > 0) {
        const cpreds = where.?[0..n_where];
        predicates = c_allocator.alloc(Predicate, cpreds.len) catch {
            setError("out of memory allocating predicates", .{});
            return null;
        };
        in_owned = c_allocator.alloc([]const []const u8, cpreds.len) catch {
            setError("out of memory allocating predicates", .{});
            return null;
        };
        @memset(in_owned, &.{});
        for (cpreds, 0..) |cp, i| {
            if (cp.op == 6) {
                const cvals = cp.values.?[0..cp.n_values];
                const owned = c_allocator.alloc([]const u8, cvals.len) catch {
                    setError("out of memory allocating IN values", .{});
                    return null;
                };
                for (cvals, 0..) |cv, j| {
                    owned[j] = c_allocator.dupe(u8, std.mem.span(cv)) catch {
                        setError("out of memory allocating IN values", .{});
                        return null;
                    };
                }
                in_owned[i] = owned;
                predicates[i] = Predicate.initIn(cp.column, owned);
                continue;
            }
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

    // Straight to columnar via parallelScanColumnar() — NOT parallelScan()
    // + a re-copy into ColumnBuf like this function used to do. That
    // older version paid two real costs: parallelScan()'s OwnedRow does
    // one allocator.dupe() call per FIELD (millions of tiny allocations
    // for a large result — the same class of cost scan_bench.zig's own
    // fix eliminated at smaller scope), and then this function copied
    // AGAIN from OwnedRow into ColumnBuf. parallelScanColumnar()'s
    // workers write directly into per-worker ColumnBuf (amortized
    // ArrayList growth, no per-field allocations) and this function now
    // just takes ownership of its output directly — zero re-copy, since
    // CollectColumnarCtx.columns IS scan.ColumnBuf, not a
    // separate type that needs converting.
    var result = scan.parallelScanColumnar(c_allocator, std.mem.span(p), delimiter, predicates, num_threads) catch |e| {
        setError("parallel scan failed: {s}", .{@errorName(e)});
        return null;
    };

    const cc = c_allocator.create(CollectColumnarCtx) catch {
        setError("out of memory allocating columnar collect context", .{});
        result.deinit();
        return null;
    };
    cc.* = .{ .columns = result.columns, .n_rows = result.n_rows, .n_cols = result.n_cols };
    return cc;
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
    for (c.in_values) |vals| {
        for (vals) |v| c_allocator.free(@constCast(v));
        if (vals.len > 0) c_allocator.free(@constCast(vals));
    }
    if (c.in_values.len > 0) c_allocator.free(c.in_values);
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

test "C ABI: open with an IN predicate" {
    const path = "test_c_api_in.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,color\n1,red\n2,yellow\n3,blue\n4,green\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const values = [_][*:0]const u8{ "yellow", "green" };
    const preds = [_]CPredicate{.{ .column = 1, .op = 6, .value = "", .values = &values, .n_values = 2 }};
    const opts = COptions{ .columns = null, .n_columns = 0, .where = &preds, .n_where = 1, .limit = -1 };
    const ctx = scanio_open(path, &opts);
    try std.testing.expect(ctx != null);
    defer scanio_close(ctx);

    var fields: [*]const [*:0]const u8 = undefined;
    var n: usize = 0;
    try std.testing.expectEqual(@as(c_int, 1), scanio_next(ctx, &fields, &n));
    try std.testing.expectEqualStrings("2", std.mem.span(fields[0]));
    try std.testing.expectEqual(@as(c_int, 1), scanio_next(ctx, &fields, &n));
    try std.testing.expectEqualStrings("4", std.mem.span(fields[0]));
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

test "C ABI: scanio_order_by walks results ascending" {
    const path = "test_c_api_orderby.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount\n1,50\n2,1500\n3,900\n4,3000\n5,200\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctx = scanio_open(path, null);
    defer scanio_close(ctx);

    const octx = scanio_order_by(ctx, 1, 0); // ascending
    try std.testing.expect(octx != null);
    defer scanio_order_by_close(octx);

    var fields: [*]const [*:0]const u8 = undefined;
    var n: usize = 0;

    try std.testing.expectEqual(@as(c_int, 1), scanio_order_by_next(octx, &fields, &n));
    try std.testing.expectEqualStrings("1", std.mem.span(fields[0])); // 50
    try std.testing.expectEqual(@as(c_int, 1), scanio_order_by_next(octx, &fields, &n));
    try std.testing.expectEqualStrings("5", std.mem.span(fields[0])); // 200
    try std.testing.expectEqual(@as(c_int, 1), scanio_order_by_next(octx, &fields, &n));
    try std.testing.expectEqualStrings("3", std.mem.span(fields[0])); // 900
    try std.testing.expectEqual(@as(c_int, 1), scanio_order_by_next(octx, &fields, &n));
    try std.testing.expectEqualStrings("2", std.mem.span(fields[0])); // 1500
    try std.testing.expectEqual(@as(c_int, 1), scanio_order_by_next(octx, &fields, &n));
    try std.testing.expectEqualStrings("4", std.mem.span(fields[0])); // 3000
    try std.testing.expectEqual(@as(c_int, 0), scanio_order_by_next(octx, &fields, &n));
}

test "C ABI: scanio_order_by composes with a WHERE-filtered ctx, descending" {
    const path = "test_c_api_orderby_filtered.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,city,amount\n1,Austin,50\n2,Denver,3000\n3,Austin,1500\n4,Austin,900\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const preds = [_]CPredicate{.{ .column = 1, .op = 0, .value = "Austin" }};
    const opts = COptions{ .columns = null, .n_columns = 0, .where = &preds, .n_where = 1, .limit = -1 };
    const ctx = scanio_open(path, &opts);
    defer scanio_close(ctx);

    const octx = scanio_order_by(ctx, 2, 1); // descending
    defer scanio_order_by_close(octx);

    var fields: [*]const [*:0]const u8 = undefined;
    var n: usize = 0;
    try std.testing.expectEqual(@as(c_int, 1), scanio_order_by_next(octx, &fields, &n));
    try std.testing.expectEqualStrings("3", std.mem.span(fields[0])); // 1500
    try std.testing.expectEqual(@as(c_int, 1), scanio_order_by_next(octx, &fields, &n));
    try std.testing.expectEqualStrings("4", std.mem.span(fields[0])); // 900
    try std.testing.expectEqual(@as(c_int, 1), scanio_order_by_next(octx, &fields, &n));
    try std.testing.expectEqualStrings("1", std.mem.span(fields[0])); // 50
    try std.testing.expectEqual(@as(c_int, 0), scanio_order_by_next(octx, &fields, &n));
}

test "C ABI: scanio_collect packs matching rows into one NUL-separated buffer" {
    const path = "test_c_api_collect.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,color,amount\n1,yellow,50\n2,red,1500\n3,yellow,900\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const preds = [_]CPredicate{.{ .column = 1, .op = 0, .value = "yellow" }};
    const opts = COptions{ .columns = null, .n_columns = 0, .where = &preds, .n_where = 1, .limit = -1 };
    const ctx = scanio_open(path, &opts);
    defer scanio_close(ctx);

    const cc = scanio_collect(ctx);
    try std.testing.expect(cc != null);
    defer scanio_collect_close(cc);

    try std.testing.expectEqual(@as(usize, 2), scanio_collect_n_rows(cc));
    try std.testing.expectEqual(@as(usize, 3), scanio_collect_n_cols(cc));

    var len: usize = 0;
    const data = scanio_collect_data(cc, &len).?;
    const buf = data[0..len];
    try std.testing.expectEqualStrings("1\x00yellow\x0050\x003\x00yellow\x00900\x00", buf);
}

test "C ABI: scanio_collect on zero matches returns n_rows=0 and a null buffer" {
    const path = "test_c_api_collect_empty.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,color\n1,red\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const preds = [_]CPredicate{.{ .column = 1, .op = 0, .value = "yellow" }};
    const opts = COptions{ .columns = null, .n_columns = 0, .where = &preds, .n_where = 1, .limit = -1 };
    const ctx = scanio_open(path, &opts);
    defer scanio_close(ctx);

    const cc = scanio_collect(ctx);
    defer scanio_collect_close(cc);

    try std.testing.expectEqual(@as(usize, 0), scanio_collect_n_rows(cc));
    var len: usize = 0;
    try std.testing.expect(scanio_collect_data(cc, &len) == null);
    try std.testing.expectEqual(@as(usize, 0), len);
}

fn columnarValue(cc: *CollectColumnarCtx, col_idx: usize, row_idx: usize) []const u8 {
    var data_len: usize = 0;
    const data = scanio_collect_columnar_data(cc, col_idx, &data_len) orelse "";
    var off_len: usize = 0;
    const offsets = scanio_collect_columnar_offsets(cc, col_idx, &off_len).?;
    const start = offsets[row_idx];
    const end = offsets[row_idx + 1];
    return data[start..end];
}

test "C ABI: scanio_collect_columnar packs matching rows column-major with offsets" {
    const path = "test_c_api_collect_columnar.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,color,amount\n1,yellow,50\n2,red,1500\n3,yellow,900\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const preds = [_]CPredicate{.{ .column = 1, .op = 0, .value = "yellow" }};
    const opts = COptions{ .columns = null, .n_columns = 0, .where = &preds, .n_where = 1, .limit = -1 };
    const ctx = scanio_open(path, &opts);
    defer scanio_close(ctx);

    const cc = scanio_collect_columnar(ctx);
    try std.testing.expect(cc != null);
    defer scanio_collect_columnar_close(cc);

    try std.testing.expectEqual(@as(usize, 2), scanio_collect_columnar_n_rows(cc));
    try std.testing.expectEqual(@as(usize, 3), scanio_collect_columnar_n_cols(cc));
    try std.testing.expectEqualStrings("1", columnarValue(cc.?, 0, 0));
    try std.testing.expectEqualStrings("3", columnarValue(cc.?, 0, 1));
    try std.testing.expectEqualStrings("yellow", columnarValue(cc.?, 1, 0));
    try std.testing.expectEqualStrings("yellow", columnarValue(cc.?, 1, 1));
    try std.testing.expectEqualStrings("50", columnarValue(cc.?, 2, 0));
    try std.testing.expectEqualStrings("900", columnarValue(cc.?, 2, 1));
}

test "C ABI: scanio_parallel_collect_columnar matches scanio_collect_columnar on the same data" {
    const path = "test_c_api_parallel_collect.csv";
    var data: std.ArrayList(u8) = .{};
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, "id,city,amount\n");
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const city = if (i % 3 == 0) "Austin" else "Denver";
        try data.writer(std.testing.allocator).print("{d},{s},{d}\n", .{ i, city, i * 3 });
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data.items });
    defer std.fs.cwd().deleteFile(path) catch {};

    const preds = [_]CPredicate{.{ .column = 1, .op = 0, .value = "Austin" }};
    const opts = COptions{ .columns = null, .n_columns = 0, .where = &preds, .n_where = 1, .limit = -1 };
    const ctx = scanio_open(path, &opts);
    const single = scanio_collect_columnar(ctx);
    defer scanio_collect_columnar_close(single);
    scanio_close(ctx);

    const par = scanio_parallel_collect_columnar(path, ',', &preds, 1, 4);
    try std.testing.expect(par != null);
    defer scanio_collect_columnar_close(par);

    try std.testing.expectEqual(scanio_collect_columnar_n_rows(single), scanio_collect_columnar_n_rows(par));
    try std.testing.expectEqual(scanio_collect_columnar_n_cols(single), scanio_collect_columnar_n_cols(par));

    // Row order isn't guaranteed to match (parallel path concatenates
    // worker ranges, not necessarily identical row-for-row ordering vs
    // the single-threaded path for every possible split) — so verify
    // via id-column SET equality instead of positional equality.
    var single_ids = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer single_ids.deinit();
    const n = scanio_collect_columnar_n_rows(single);
    var r: usize = 0;
    while (r < n) : (r += 1) {
        const id = std.fmt.parseInt(u64, columnarValue(single.?, 0, r), 10) catch unreachable;
        try single_ids.put(id, {});
    }
    r = 0;
    while (r < n) : (r += 1) {
        const id = std.fmt.parseInt(u64, columnarValue(par.?, 0, r), 10) catch unreachable;
        try std.testing.expect(single_ids.contains(id));
    }
}

test "C ABI: max_column bounds the row without breaking the result" {
    const path = "test_c_api_max_column.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,city,amount,notes,extra\n1,Austin,50,x,y\n2,Austin,1500,x,y\n3,Denver,1500,x,y\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const cols = [_]usize{0};
    const preds = [_]CPredicate{
        .{ .column = 1, .op = 0, .value = "Austin" },
        .{ .column = 2, .op = 2, .value = "1000" },
    };
    const opts = COptions{ .columns = &cols, .n_columns = 1, .where = &preds, .n_where = 2, .limit = -1, .max_column = 2 };
    const ctx = scanio_open(path, &opts);
    try std.testing.expect(ctx != null);
    defer scanio_close(ctx);

    var fields: [*]const [*:0]const u8 = undefined;
    var n: usize = 0;
    try std.testing.expectEqual(@as(c_int, 1), scanio_next(ctx, &fields, &n));
    try std.testing.expectEqualStrings("2", std.mem.span(fields[0]));
    try std.testing.expectEqual(@as(c_int, 0), scanio_next(ctx, &fields, &n));
}
