//! Private CPython interfaces: borrowed views, never row JSON.
const std = @import("std");
const scan = @import("scanio");
const A = std.heap.c_allocator;
const Slice = extern struct { ptr: [*]const u8, len: usize };
const Failure = extern struct { column: usize, name: Slice, rule: Slice, value: Slice, row: u64 };
const Emit = *const fn (?*anyopaque, [*]const Slice, usize, [*]const Failure, usize, u64, f64, c_int) callconv(.c) c_int;
fn view(s: []const u8) Slice {
    return .{ .ptr = s.ptr, .len = s.len };
}
fn fail(buf: *[256]u8, err: anyerror) c_int {
    _ = std.fmt.bufPrintZ(buf, "{s}", .{@errorName(err)}) catch {};
    return -1;
}
const Where = struct { column: usize, op: u8, value: []const u8 = "", values: []const []const u8 = &.{} };
const Options = struct { columns: ?[]const usize = null, where: []const Where = &.{}, limit: ?usize = null, max_column: ?usize = null, negate: bool = false };
const Buffers = struct {
    fields: std.ArrayListUnmanaged(Slice) = .{},
    errors: std.ArrayListUnmanaged(Failure) = .{},
    fn deinit(b: *Buffers) void {
        b.fields.deinit(A);
        b.errors.deinit(A);
    }
    fn send(b: *Buffers, fields: []const []const u8, errors: []const scan.RowError, number: u64, key: f64, kind: c_int, ctx: ?*anyopaque, emit: Emit) !void {
        b.fields.clearRetainingCapacity();
        b.errors.clearRetainingCapacity();
        for (fields) |f| try b.fields.append(A, view(f));
        for (errors) |e| try b.errors.append(A, .{ .column = e.column orelse std.math.maxInt(usize), .name = view(e.column_name), .rule = view(e.kind.name()), .value = view(e.value), .row = e.row });
        if (emit(ctx, b.fields.items.ptr, b.fields.items.len, b.errors.items.ptr, b.errors.items.len, number, key, kind) != 0) return error.CallbackFailed;
    }
};
const QueryCtx = struct {
    q: scan.Query,
    parsed: std.json.Parsed(Options),
    predicates: []scan.Predicate,
    path: []u8,
    buffers: Buffers = .{},
    fn open(path: []const u8, options: []const u8) !*QueryCtx {
        const parsed = try std.json.parseFromSlice(Options, A, options, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const preds = try A.alloc(scan.Predicate, parsed.value.where.len);
        errdefer A.free(preds);
        for (parsed.value.where, 0..) |p, i| {
            if (p.op > 6) return error.BadPredicate;
            preds[i] = if (p.op == 6) scan.Predicate.initIn(p.column, p.values) else scan.Predicate.init(p.column, @enumFromInt(p.op), p.value);
        }
        var q = try scan.Query.open(A, path, .{ .columns = parsed.value.columns, .where = preds, .limit = parsed.value.limit, .negate = parsed.value.negate, .stop_after_column = parsed.value.max_column });
        errdefer q.deinit();
        const n = q.header().len;
        if (parsed.value.columns) |cols| for (cols) |col| {
            if (col >= n) return error.UnknownColumn;
        };
        for (preds) |p| if (p.column >= n) return error.UnknownColumn;
        const owned_path = try A.dupe(u8, path);
        errdefer A.free(owned_path);
        const c = try A.create(QueryCtx);
        c.* = .{ .q = q, .parsed = parsed, .predicates = preds, .path = owned_path };
        return c;
    }
};
export fn py_query_open(path: [*]const u8, n: usize, opts: [*]const u8, m: usize, err: *[256]u8) ?*QueryCtx {
    return QueryCtx.open(path[0..n], opts[0..m]) catch |e| {
        _ = fail(err, e);
        return null;
    };
}
export fn py_query_close(c: *QueryCtx) void {
    c.q.deinit();
    c.parsed.deinit();
    A.free(c.predicates);
    A.free(c.path);
    c.buffers.deinit();
    A.destroy(c);
}
export fn py_query_ncols(c: *QueryCtx) usize {
    return if (c.q.columns) |cols| cols.len else c.q.header().len;
}
export fn py_query_name(c: *QueryCtx, i: usize) Slice {
    return view(c.q.header()[if (c.q.columns) |cols| cols[i] else i]);
}
// Preserve the former JSON-byte batch budget without allocating/encoding JSON.
fn stringSize(s: []const u8) usize {
    var n: usize = 2;
    for (s) |ch| n += switch (ch) {
        '"', '\\', '\n', '\r', '\t', 8, 12 => 2,
        0...7, 11, 14...31 => 6,
        else => 1,
    };
    return n;
}
fn digits(n: u64) usize {
    var x = n;
    var len: usize = 1;
    while (x >= 10) : (x /= 10) len += 1;
    return len;
}
fn fieldsSize(fields: []const []const u8) usize {
    var n: usize = 2;
    for (fields, 0..) |f, i| n += stringSize(f) + @intFromBool(i > 0);
    return n;
}
fn errorsSize(errors: []const scan.RowError) usize {
    var n: usize = 2;
    for (errors, 0..) |e, i| n += @intFromBool(i > 0) + "{\"row\":".len + digits(e.row) + ",\"column\":".len + (if (e.column) |col| digits(col) else @as(usize, 4)) + ",\"column_name\":".len + stringSize(e.column_name) + ",\"rule\":".len + stringSize(e.kind.name()) + ",\"value\":".len + stringSize(e.value) + 1;
    return n;
}
export fn py_query_next(c: *QueryCtx, max_rows: usize, target: usize, ctx: ?*anyopaque, emit: Emit, err: *[256]u8) c_int {
    var bytes: usize = 1;
    var rows: usize = 0;
    while (rows < max_rows) : (rows += 1) {
        const row = (c.q.next() catch |e| return fail(err, e)) orelse return 0;
        c.buffers.send(row.fields, &.{}, 0, 0, 0, ctx, emit) catch |e| return fail(err, e);
        bytes += @intFromBool(rows > 0) + fieldsSize(row.fields);
        if (bytes >= target) break;
    }
    return 1;
}
/// Unfiltered row count via the multi-threaded engine, bypassing QueryCtx
/// entirely (parallelCountRows() opens its own per-worker file views —
/// no single already-open Query/Scanner to hand it). Real, measured win
/// over Query.count()'s single-threaded newline-count fast path: 0.05s ->
/// 0.01-0.03s on a 417MB/1M-row file (see ROADMAP.md).
export fn py_count_rows_parallel(path: [*]const u8, n: usize, out: *u64, err: *[256]u8) c_int {
    out.* = @intCast(scan.parallelCountRows(A, path[0..n], 0) catch |e| return fail(err, e));
    return 0;
}
const CountWhereOptions = struct { where: []const Where = &.{}, negate: bool = false };
/// WHERE-filtered row count via the multi-threaded engine — same
/// bypass-QueryCtx shape as py_count_rows_parallel() above, since
/// parallelCountRowsWhere() opens its own per-worker file views too.
/// Real, measured win over Query.count()'s single-threaded loop: 0.097s
/// -> 0.015-0.017s on a low-selectivity, early-column WHERE (417MB/1M
/// rows/51 cols, see ROADMAP.md). parallelCountRowsWhere() itself now
/// skips spawning a thread at all below threadsFor()'s size threshold
/// (fixed after a real Windows-only crash traced to spawning one
/// unconditionally, even for a 3-row file — see ROADMAP.md).
export fn py_count_rows_where_parallel(path: [*]const u8, path_len: usize, opts: [*]const u8, opts_len: usize, out: *u64, err: *[256]u8) c_int {
    const parsed = std.json.parseFromSlice(CountWhereOptions, A, opts[0..opts_len], .{ .allocate = .alloc_always }) catch |e| return fail(err, e);
    defer parsed.deinit();
    const preds = A.alloc(scan.Predicate, parsed.value.where.len) catch |e| return fail(err, e);
    defer A.free(preds);
    for (parsed.value.where, 0..) |p, i| {
        if (p.op > 6) return fail(err, error.BadPredicate);
        preds[i] = if (p.op == 6) scan.Predicate.initIn(p.column, p.values) else scan.Predicate.init(p.column, @enumFromInt(p.op), p.value);
    }
    out.* = @intCast(scan.parallelCountRowsWhere(A, path[0..path_len], ',', preds, parsed.value.negate, 0) catch |e| return fail(err, e));
    return 0;
}
const Agg = extern struct { count: u64, sum: f64, min: f64, max: f64, avg: f64, has_values: c_int };
export fn py_query_aggregate(c: *QueryCtx, col: usize, out: *Agg, err: *[256]u8) c_int {
    if (col >= c.q.header().len) return fail(err, error.UnknownColumn);
    const r = scan.aggregate(&c.q, col) catch |e| return fail(err, e);
    out.* = .{ .count = r.count, .sum = r.sum, .min = r.min orelse 0, .max = r.max orelse 0, .avg = r.avg() orelse 0, .has_values = @intFromBool(r.count > 0) };
    return 0;
}
const GroupEntry = struct { key: Slice, agg: Agg };
/// Owns the underlying GroupByResult (arena + hash map) and a flat
/// entries array materialized once at build time -- CPython indexes by
/// position (py_group_by_key/py_group_by_agg), not by iterating a hash
/// map across the FFI boundary, which Zig's StringHashMap iterator isn't
/// shaped for anyway (no stable external cursor).
const PyGroupByResult = struct {
    result: scan.GroupByResult,
    entries: []GroupEntry,
};
fn buildEntries(result: scan.GroupByResult) ![]GroupEntry {
    const entries = try A.alloc(GroupEntry, result.groups.count());
    var it = result.groups.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        const r = e.value_ptr.*;
        entries[i] = .{ .key = view(e.key_ptr.*), .agg = .{ .count = r.count, .sum = r.sum, .min = r.min orelse 0, .max = r.max orelse 0, .avg = r.avg() orelse 0, .has_values = @intFromBool(r.count > 0) } };
    }
    return entries;
}
/// Single-threaded, composes with WHERE (already applied via QueryCtx.open) --
/// same-shape counterpart to py_query_aggregate above, per group instead
/// of over the whole column. Works on CSV/NDJSON/JSON, same as groupBy()
/// itself (format-agnostic by construction, see its own doc comment).
export fn py_group_by(c: *QueryCtx, group_col: usize, agg_col: usize, err: *[256]u8) ?*PyGroupByResult {
    const n = c.q.header().len;
    if (group_col >= n or agg_col >= n) {
        _ = fail(err, error.UnknownColumn);
        return null;
    }
    var result = scan.groupBy(A, &c.q, group_col, agg_col) catch |e| {
        _ = fail(err, e);
        return null;
    };
    errdefer result.deinit();
    const entries = buildEntries(result) catch |e| {
        _ = fail(err, e);
        return null;
    };
    const p = A.create(PyGroupByResult) catch |e| {
        A.free(entries);
        result.deinit();
        _ = fail(err, e);
        return null;
    };
    p.* = .{ .result = result, .entries = entries };
    return p;
}
/// Parallel, CSV-only, no WHERE (see parallelGroupBy()'s own doc comment
/// for why) -- bypasses QueryCtx entirely, same bypass shape
/// py_count_rows_parallel already uses, since parallelGroupBy() opens
/// its own per-worker file views.
export fn py_group_by_parallel(path: [*]const u8, path_len: usize, group_col: usize, agg_col: usize, err: *[256]u8) ?*PyGroupByResult {
    var result = scan.parallelGroupBy(A, path[0..path_len], ',', group_col, agg_col, 0) catch |e| {
        _ = fail(err, e);
        return null;
    };
    errdefer result.deinit();
    const entries = buildEntries(result) catch |e| {
        _ = fail(err, e);
        return null;
    };
    const p = A.create(PyGroupByResult) catch |e| {
        A.free(entries);
        result.deinit();
        _ = fail(err, e);
        return null;
    };
    p.* = .{ .result = result, .entries = entries };
    return p;
}
export fn py_group_by_count(p: *PyGroupByResult) usize {
    return p.entries.len;
}
export fn py_group_by_key(p: *PyGroupByResult, i: usize) Slice {
    return p.entries[i].key;
}
export fn py_group_by_agg(p: *PyGroupByResult, i: usize, out: *Agg) void {
    out.* = p.entries[i].agg;
}
export fn py_group_by_close(p: *PyGroupByResult) void {
    A.free(p.entries);
    p.result.deinit();
    A.destroy(p);
}
export fn py_query_sort(c: *QueryCtx, col: usize, k: usize, desc: c_int, top: c_int, ctx: ?*anyopaque, emit: Emit, err: *[256]u8) c_int {
    if (col >= c.q.header().len) return fail(err, error.UnknownColumn);
    if (top != 0) {
        var result = scan.topK(A, &c.q, col, k, desc != 0) catch |e| return fail(err, e);
        defer result.deinit();
        for (result.getSorted()) |entry| c.buffers.send(entry.row.fields, &.{}, 0, entry.key, 2, ctx, emit) catch |e| return fail(err, e);
    } else {
        var result = scan.orderBy(A, &c.q, col, desc != 0) catch |e| return fail(err, e);
        defer result.deinit();
        for (result.rows) |row| c.buffers.send(row.fields, &.{}, 0, 0, 0, ctx, emit) catch |e| return fail(err, e);
    }
    return 0;
}
const Columnar = scan.ColumnarScanResult;
export fn py_columnar(c: *QueryCtx, err: *[256]u8) ?*Columnar {
    var r = scan.parallelScanColumnar(A, c.path, ',', c.predicates, c.q.negate, 0) catch |e| {
        _ = fail(err, e);
        return null;
    };
    const p = A.create(Columnar) catch |e| {
        r.deinit();
        _ = fail(err, e);
        return null;
    };
    p.* = r;
    return p;
}
export fn py_columnar_close(c: *Columnar) void {
    c.deinit();
    A.destroy(c);
}
export fn py_columnar_nrows(c: *Columnar) usize {
    return c.n_rows;
}
export fn py_columnar_ncols(c: *Columnar) usize {
    return c.n_cols;
}
export fn py_columnar_data(c: *Columnar, col: usize) Slice {
    return view(c.columns[col].data.items);
}
export fn py_columnar_offsets(c: *Columnar, col: usize) Slice {
    return view(std.mem.sliceAsBytes(c.columns[col].offsets.items));
}
const ValidatorCtx = struct { v: scan.Validator, buffers: Buffers = .{} };
export fn py_validator_open(path: [*]const u8, n: usize, schema: [*]const u8, m: usize, err: *[256]u8) ?*ValidatorCtx {
    var v = scan.Validator.openJson(A, path[0..n], schema[0..m]) catch |e| {
        _ = fail(err, e);
        return null;
    };
    const c = A.create(ValidatorCtx) catch |e| {
        v.deinit();
        _ = fail(err, e);
        return null;
    };
    c.* = .{ .v = v };
    return c;
}
export fn py_validator_close(c: *ValidatorCtx) void {
    c.v.deinit();
    c.buffers.deinit();
    A.destroy(c);
}
export fn py_validator_ncols(c: *ValidatorCtx) usize {
    return c.v.header().len;
}
export fn py_validator_name(c: *ValidatorCtx, i: usize) Slice {
    return view(c.v.header()[i]);
}
export fn py_validator_next(c: *ValidatorCtx, max_rows: usize, target: usize, ctx: ?*anyopaque, emit: Emit, err: *[256]u8) c_int {
    var bytes: usize = 1;
    var rows: usize = 0;
    while (rows < max_rows) : (rows += 1) {
        const item = (c.v.nextOutcome(true) catch |e| return fail(err, e)) orelse return 0;
        c.buffers.send(item.row.fields, item.errors, item.number, 0, 1, ctx, emit) catch |e| return fail(err, e);
        bytes += @intFromBool(rows > 0) + "{\"number\":".len + digits(item.number) + ",\"values\":".len + fieldsSize(item.row.fields) + 1;
        if (item.errors.len > 0) bytes += ",\"errors\":".len + errorsSize(item.errors);
        if (bytes >= target) break;
    }
    return 1;
}
const ReportStats = extern struct { total: u64, valid: u64, invalid: u64, errors: u64, truncated: c_int, counts: [9]u64 };
export fn py_validator_report(c: *ValidatorCtx, max_errors: usize, out: *ReportStats, ctx: ?*anyopaque, emit: Emit, err: *[256]u8) c_int {
    var r = c.v.report(.{ .max_errors = if (max_errors == 0) 100 else max_errors }) catch |e| return fail(err, e);
    defer r.deinit();
    out.* = .{ .total = r.rows_total, .valid = r.rows_valid, .invalid = r.rows_invalid, .errors = r.errors_total, .truncated = @intFromBool(r.truncated), .counts = r.counts };
    c.buffers.send(&.{}, r.errors, 0, 0, 3, ctx, emit) catch |e| return fail(err, e);
    return 0;
}
export fn py_import(path: [*]const u8, n: usize, schema: [*]const u8, m: usize, good: [*]const u8, ng: usize, bad: [*]const u8, nb: usize, out: *scan.validation_import.Stats, err: *[256]u8) c_int {
    out.* = scan.validation_import.run(A, path[0..n], schema[0..m], good[0..ng], bad[0..nb]) catch |e| return fail(err, e);
    return 0;
}

// Dispatch-path regression guard, not just correctness: these two exports
// exist because parallelCountRows()/parallelCountRowsWhere() sat fully
// built and correct but uncalled by this file for an unknown period —
// invisible to every prior test, since the single-threaded fallback gave
// the same answer, just slower (see ROADMAP.md). A correctness-only test
// would pass whether or not the fix regressed; asserting
// parallel_debug.debug_spawn_count actually increases proves the
// multi-threaded engine, not a scan fallback, produced the answer.
test "py_count_rows_parallel dispatches to the multi-threaded engine, not a fallback scan" {
    const allocator = std.testing.allocator;
    const path = "test_python_api_dispatch.csv";
    var data: std.ArrayList(u8) = .{};
    defer data.deinit(allocator);
    try data.appendSlice(allocator, "id,name\n");
    var i: usize = 0;
    while (i < 200_000) : (i += 1) try data.writer(allocator).print("{d},row-{d}\n", .{ i, i });
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data.items });
    defer std.fs.cwd().deleteFile(path) catch {};

    var out: u64 = 0;
    var err: [256]u8 = undefined;
    const before = scan.parallel_debug.debug_spawn_count.load(.monotonic);
    try std.testing.expectEqual(@as(c_int, 0), py_count_rows_parallel(path.ptr, path.len, &out, &err));
    try std.testing.expectEqual(@as(u64, 200_000), out);
    try std.testing.expect(scan.parallel_debug.debug_spawn_count.load(.monotonic) > before);
}

test "py_count_rows_where_parallel dispatches to the multi-threaded engine, not a fallback scan" {
    const allocator = std.testing.allocator;
    const path = "test_python_api_dispatch_where.csv";
    var data: std.ArrayList(u8) = .{};
    defer data.deinit(allocator);
    try data.appendSlice(allocator, "id,name\n");
    var i: usize = 0;
    while (i < 200_000) : (i += 1) try data.writer(allocator).print("{d},row-{d}\n", .{ i, i });
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data.items });
    defer std.fs.cwd().deleteFile(path) catch {};

    const opts = "{\"where\":[{\"column\":1,\"op\":0,\"value\":\"row-5\"}]}";
    var out: u64 = 0;
    var err: [256]u8 = undefined;
    const before = scan.parallel_debug.debug_spawn_count.load(.monotonic);
    try std.testing.expectEqual(@as(c_int, 0), py_count_rows_where_parallel(path.ptr, path.len, opts.ptr, opts.len, &out, &err));
    try std.testing.expectEqual(@as(u64, 1), out);
    try std.testing.expect(scan.parallel_debug.debug_spawn_count.load(.monotonic) > before);
}

// The exact regression guard for the crash this fix closes: a 3-row
// file (below threadsFor()'s threshold) must NOT spawn a thread at all.
test "py_count_rows_where_parallel: tiny file does not spawn a thread" {
    const path = "test_python_api_tiny_where.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "id,amount,label\n1,10,alpha\n2,-2,beta\n3,oops,quoted\n" });
    defer std.fs.cwd().deleteFile(path) catch {};

    const opts = "{\"where\":[{\"column\":0,\"op\":3,\"value\":\"2\"}]}";
    var out: u64 = 0;
    var err: [256]u8 = undefined;
    const before = scan.parallel_debug.debug_spawn_count.load(.monotonic);
    try std.testing.expectEqual(@as(c_int, 0), py_count_rows_where_parallel(path.ptr, path.len, opts.ptr, opts.len, &out, &err));
    try std.testing.expectEqual(@as(u64, 2), out);
    try std.testing.expectEqual(before, scan.parallel_debug.debug_spawn_count.load(.monotonic));
}
