//! Node.js N-API binding for libscanio — the only Node binding this
//! project ships.
//!
//! Compiled directly against Node's own `node_api.h`, no dynamic-FFI
//! layer at all: this file calls the SAME Zig core (`Query`,
//! `aggregate`, `topK`, `orderBy`, `parallelScanColumnar`) every other
//! binding uses, directly, not through c_api.zig's C-struct boundary —
//! there is no struct marshaling to have a bug in at all, in either
//! language. See ROADMAP.md's M5b entry for the history of why this
//! design was chosen.
//!
//! Every exported function is JSON/plain-string in, JSON/plain-value
//! out (same "text in, text out" shape csvql's own N-API addon uses,
//! this project's sibling and the source of this whole pattern) —
//! WHERE clauses are parsed HERE in Zig (parseWhereString below),
//! mirroring a simple "col OP val [AND col OP val ...]" / "col IN
//! (a,b,c)" grammar, done once, in one language, reusable by any
//! future binding.
//!
//! Modeled directly on csvql's own `src/node_binding.zig` (this
//! project's sibling, same author) — same author already solved the
//! two real dlopen()-into-Node gotchas that would otherwise bite here
//! too, the hard way:
//!   1. `std.heap.c_allocator`, NOT a `GeneralPurposeAllocator` — a GPA's
//!      own `PageAllocator` faults once this shared object is dlopen()ed
//!      into Node's process (a real, previously-hit SIGSEGV in that
//!      project, not a theoretical concern).
//!   2. Run the actual work on a dedicated thread with a large stack.
//!      Node hands an N-API call whatever stack V8 already partly
//!      consumed; libscanio's own scan path allocates real per-row field
//!      buffers on it (see `parallel.zig`'s worker structs) and a shared
//!      host stack is not a safe assumption to make about that.
const std = @import("std");
const scan = @import("scanio");
const Query = scan.Query;
const Predicate = scan.Predicate;
const Op = scan.Op;

const napi = @cImport(@cInclude("node_api.h"));

const c_allocator = std.heap.c_allocator;
const worker_stack_size = 16 * 1024 * 1024;

// WHERE-string parsing, column resolution, and header probing live in
// where_parser.zig — split out specifically so they're testable via
// plain `zig build test`, without needing Node's headers the way this
// file's own `@cImport(@cInclude("node_api.h"))` does. See that file's
// own doc comment and its adversarial test coverage.
const where_parser = @import("where_parser.zig");
const resolveColumn = where_parser.resolveColumn;
const parseWhereString = where_parser.parseWhereString;
const freePredicates = where_parser.freePredicates;
const parseColumnsJson = where_parser.parseColumnsJson;
const probeHeader = where_parser.probeHeader;
const freeHeader = where_parser.freeHeader;

// ── N-API helpers ────────────────────────────────────────────────────

fn napiFail(env: napi.napi_env, msg: [:0]const u8) napi.napi_value {
    _ = napi.napi_throw_error(env, null, msg.ptr);
    var undef: napi.napi_value = undefined;
    _ = napi.napi_get_undefined(env, &undef);
    return undef;
}

fn failErr(env: napi.napi_env, err: anyerror) napi.napi_value {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "{s}", .{@errorName(err)}) catch "error";
    return napiFail(env, msg);
}

fn napiString(env: napi.napi_env, s: []const u8) napi.napi_value {
    var out: napi.napi_value = undefined;
    _ = napi.napi_create_string_utf8(env, s.ptr, s.len, &out);
    return out;
}

fn napiInt64(env: napi.napi_env, v: i64) napi.napi_value {
    var out: napi.napi_value = undefined;
    _ = napi.napi_create_int64(env, v, &out);
    return out;
}

/// Shared by every getXArg() below: fetches all call args once and
/// returns the one at `index`, or null if it wasn't passed at all (or
/// was passed as JS `null`/`undefined`, treated the same as "not
/// passed" throughout this file's optional-argument convention). Used
/// to be duplicated — the argc/args array setup and null/undefined
/// check were copy-pasted into getStringArg/getIntArg/getBoolArg
/// separately before this was pulled out.
fn getRawArg(env: napi.napi_env, info: napi.napi_callback_info, index: usize) ?napi.napi_value {
    var argc: usize = 6;
    var args: [6]napi.napi_value = undefined;
    _ = napi.napi_get_cb_info(env, info, &argc, &args, null, null);
    if (argc <= index) return null;
    var value_type: napi.napi_valuetype = undefined;
    _ = napi.napi_typeof(env, args[index], &value_type);
    if (value_type == napi.napi_null or value_type == napi.napi_undefined) return null;
    return args[index];
}

fn getStringArg(env: napi.napi_env, info: napi.napi_callback_info, index: usize, allocator: std.mem.Allocator) ![:0]u8 {
    const arg = getRawArg(env, info, index) orelse return error.MissingArgument;
    var len: usize = 0;
    _ = napi.napi_get_value_string_utf8(env, arg, null, 0, &len);
    const buf = try allocator.allocSentinel(u8, len, 0);
    _ = napi.napi_get_value_string_utf8(env, arg, buf.ptr, len + 1, &len);
    return buf;
}

fn getOptionalStringArg(env: napi.napi_env, info: napi.napi_callback_info, index: usize, allocator: std.mem.Allocator) !?[:0]u8 {
    return getStringArg(env, info, index, allocator) catch |e| switch (e) {
        error.MissingArgument => null,
        else => return e,
    };
}

fn getIntArg(env: napi.napi_env, info: napi.napi_callback_info, index: usize, comptime T: type, default: T) T {
    const arg = getRawArg(env, info, index) orelse return default;
    var v: i64 = 0;
    _ = napi.napi_get_value_int64(env, arg, &v);
    return @intCast(v);
}

fn getBoolArg(env: napi.napi_env, info: napi.napi_callback_info, index: usize, default: bool) bool {
    const arg = getRawArg(env, info, index) orelse return default;
    var v: bool = default;
    _ = napi.napi_get_value_bool(env, arg, &v);
    return v;
}

fn runOnWorkerStack(comptime WorkFn: anytype, args: anytype) void {
    const t = std.Thread.spawn(.{ .stack_size = worker_stack_size }, WorkFn, args) catch return;
    t.join();
}

fn jsonEscapedString(w: *std.io.Writer, s: []const u8) void {
    std.json.Stringify.value(s, .{}, w) catch {};
}

// ── schema ───────────────────────────────────────────────────────────

const SchemaResult = struct { json: []const u8 = "", err: ?anyerror = null };

fn schemaWork(path: [:0]const u8, out: *SchemaResult) void {
    const header = probeHeader(c_allocator, path) catch |e| {
        out.err = e;
        return;
    };
    defer freeHeader(c_allocator, header);

    var aw = std.io.Writer.Allocating.init(c_allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeByte('[') catch return;
    for (header, 0..) |name, i| {
        if (i > 0) w.writeByte(',') catch return;
        jsonEscapedString(w, name);
    }
    w.writeByte(']') catch return;
    out.json = aw.toOwnedSlice() catch return;
}

fn napiSchema(env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
    const path = getStringArg(env, info, 0, c_allocator) catch return napiFail(env, "schemaJson(path): path argument required");
    defer c_allocator.free(path);

    var result = SchemaResult{};
    runOnWorkerStack(schemaWork, .{ path, &result });
    if (result.err) |e| return failErr(env, e);
    defer c_allocator.free(result.json);
    return napiString(env, result.json);
}

// ── count ────────────────────────────────────────────────────────────

const CountResult = struct { count: i64 = 0, err: ?anyerror = null };

fn countWork(path: [:0]const u8, where: ?[:0]const u8, out: *CountResult) void {
    var predicates: []Predicate = &.{};
    var header: [][]const u8 = &.{};
    defer if (header.len > 0) freeHeader(c_allocator, header);
    defer if (predicates.len > 0) freePredicates(c_allocator, predicates);

    if (where) |w| {
        header = probeHeader(c_allocator, path) catch |e| {
            out.err = e;
            return;
        };
        predicates = parseWhereString(c_allocator, header, w) catch |e| {
            out.err = e;
            return;
        };
    }

    var q = Query.open(c_allocator, path, .{
        .where = predicates,
        // count() never returns field data — always safe to bound to
        // just the WHERE predicates' columns. Real, measured win: ~7x
        // faster on this fixture's WHERE-filtered count (330ms -> ~45ms)
        // once this bound was wired up (see ROADMAP.md's M5b follow-up).
        .stop_after_column = where_parser.maxPredicateColumn(predicates, null),
    }) catch |e| {
        out.err = e;
        return;
    };
    defer q.deinit();
    out.count = @intCast(q.count() catch |e| {
        out.err = e;
        return;
    });
}

fn napiCount(env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
    const path = getStringArg(env, info, 0, c_allocator) catch return napiFail(env, "countJson(path): path argument required");
    defer c_allocator.free(path);
    const where = getOptionalStringArg(env, info, 1, c_allocator) catch null;
    defer if (where) |w| c_allocator.free(w);

    var result = CountResult{};
    runOnWorkerStack(countWork, .{ path, where, &result });
    if (result.err) |e| return failErr(env, e);
    return napiInt64(env, result.count);
}

// ── aggregate ────────────────────────────────────────────────────────

const AggregateResult = struct { json: []const u8 = "", err: ?anyerror = null };

fn aggregateWork(path: [:0]const u8, column_name: [:0]const u8, where: ?[:0]const u8, out: *AggregateResult) void {
    const header = probeHeader(c_allocator, path) catch |e| {
        out.err = e;
        return;
    };
    defer freeHeader(c_allocator, header);

    const column = resolveColumn(header, column_name) catch |e| {
        out.err = e;
        return;
    };

    var predicates: []Predicate = &.{};
    defer if (predicates.len > 0) freePredicates(c_allocator, predicates);
    if (where) |w| {
        predicates = parseWhereString(c_allocator, header, w) catch |e| {
            out.err = e;
            return;
        };
    }

    var q = Query.open(c_allocator, path, .{
        .where = predicates,
        // aggregate() only ever reads `column` — safe to bound to
        // max(predicate columns, column).
        .stop_after_column = where_parser.maxPredicateColumn(predicates, column),
    }) catch |e| {
        out.err = e;
        return;
    };
    defer q.deinit();
    const agg = scan.aggregate(&q, column) catch |e| {
        out.err = e;
        return;
    };

    var aw = std.io.Writer.Allocating.init(c_allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.print("{{\"count\":{d},\"sum\":{d},", .{ agg.count, agg.sum }) catch return;
    if (agg.min) |m| w.print("\"min\":{d},", .{m}) catch return else w.writeAll("\"min\":null,") catch return;
    if (agg.max) |m| w.print("\"max\":{d},", .{m}) catch return else w.writeAll("\"max\":null,") catch return;
    if (agg.avg()) |a| w.print("\"avg\":{d},", .{a}) catch return else w.writeAll("\"avg\":null,") catch return;
    w.print("\"has_values\":{s}}}", .{if (agg.count > 0) "true" else "false"}) catch return;
    out.json = aw.toOwnedSlice() catch return;
}

fn napiAggregate(env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
    const path = getStringArg(env, info, 0, c_allocator) catch return napiFail(env, "aggregateJson(path, column): path required");
    defer c_allocator.free(path);
    const column = getStringArg(env, info, 1, c_allocator) catch return napiFail(env, "aggregateJson(path, column): column required");
    defer c_allocator.free(column);
    const where = getOptionalStringArg(env, info, 2, c_allocator) catch null;
    defer if (where) |w| c_allocator.free(w);

    var result = AggregateResult{};
    runOnWorkerStack(aggregateWork, .{ path, column, where, &result });
    if (result.err) |e| return failErr(env, e);
    defer c_allocator.free(result.json);
    return napiString(env, result.json);
}

// ── scanArray (bulk, single call) ───────────────────────────────────

const RowsResult = struct { json: []const u8 = "", err: ?anyerror = null };

fn writeRowsJson(w: *std.io.Writer, header: []const []const u8, columns: ?[]const usize, rows_iter: anytype) !void {
    try w.writeAll("{\"names\":[");
    const names = columns orelse blk: {
        const idx = try c_allocator.alloc(usize, header.len);
        defer c_allocator.free(idx);
        for (idx, 0..) |*v, i| v.* = i;
        break :blk idx;
    };
    for (names, 0..) |ci, i| {
        if (i > 0) try w.writeByte(',');
        jsonEscapedString(w, header[ci]);
    }
    try w.writeAll("],\"rows\":[");
    try rows_iter.write(w);
    try w.writeAll("]}");
}

fn scanArrayWork(path: [:0]const u8, where: ?[:0]const u8, columns_json: ?[:0]const u8, limit: i64, out: *RowsResult) void {
    const header = probeHeader(c_allocator, path) catch |e| {
        out.err = e;
        return;
    };
    defer freeHeader(c_allocator, header);

    var predicates: []Predicate = &.{};
    defer if (predicates.len > 0) freePredicates(c_allocator, predicates);
    if (where) |w| {
        predicates = parseWhereString(c_allocator, header, w) catch |e| {
            out.err = e;
            return;
        };
    }

    const columns = parseColumnsJson(c_allocator, header, columns_json) catch |e| {
        out.err = e;
        return;
    };
    defer if (columns) |c| c_allocator.free(c);

    var q = Query.open(c_allocator, path, .{
        .where = predicates,
        .columns = columns,
        .limit = if (limit < 0) null else @intCast(limit),
    }) catch |e| {
        out.err = e;
        return;
    };
    defer q.deinit();

    var aw = std.io.Writer.Allocating.init(c_allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"names\":[") catch return;
    const proj = columns orelse blk: {
        const idx = c_allocator.alloc(usize, header.len) catch return;
        for (idx, 0..) |*v, i| v.* = i;
        break :blk idx;
    };
    defer if (columns == null) c_allocator.free(proj);
    for (proj, 0..) |ci, i| {
        if (i > 0) w.writeByte(',') catch return;
        jsonEscapedString(w, header[ci]);
    }
    w.writeAll("],\"rows\":[") catch return;
    var first = true;
    while (q.next() catch return) |row| {
        if (!first) w.writeByte(',') catch return;
        first = false;
        w.writeByte('[') catch return;
        for (row.fields, 0..) |f, i| {
            if (i > 0) w.writeByte(',') catch return;
            jsonEscapedString(w, f);
        }
        w.writeByte(']') catch return;
    }
    w.writeAll("]}") catch return;
    out.json = aw.toOwnedSlice() catch return;
}

fn napiScanArray(env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
    const path = getStringArg(env, info, 0, c_allocator) catch return napiFail(env, "scanArrayJson(path): path required");
    defer c_allocator.free(path);
    const where = getOptionalStringArg(env, info, 1, c_allocator) catch null;
    defer if (where) |w| c_allocator.free(w);
    const columns_json = getOptionalStringArg(env, info, 2, c_allocator) catch null;
    defer if (columns_json) |c| c_allocator.free(c);
    const limit = getIntArg(env, info, 3, i64, -1);

    var result = RowsResult{};
    runOnWorkerStack(scanArrayWork, .{ path, where, columns_json, limit, &result });
    if (result.err) |e| return failErr(env, e);
    defer c_allocator.free(result.json);
    return napiString(env, result.json);
}

// ── topK ─────────────────────────────────────────────────────────────

fn topkWork(path: [:0]const u8, column_name: [:0]const u8, k: usize, where: ?[:0]const u8, descending: bool, out: *RowsResult) void {
    const header = probeHeader(c_allocator, path) catch |e| {
        out.err = e;
        return;
    };
    defer freeHeader(c_allocator, header);

    const column = resolveColumn(header, column_name) catch |e| {
        out.err = e;
        return;
    };

    var predicates: []Predicate = &.{};
    defer if (predicates.len > 0) freePredicates(c_allocator, predicates);
    if (where) |w| {
        predicates = parseWhereString(c_allocator, header, w) catch |e| {
            out.err = e;
            return;
        };
    }

    var q = Query.open(c_allocator, path, .{ .where = predicates }) catch |e| {
        out.err = e;
        return;
    };
    defer q.deinit();
    var tk = scan.topK(c_allocator, &q, column, k, descending) catch |e| {
        out.err = e;
        return;
    };
    defer tk.deinit();

    var aw = std.io.Writer.Allocating.init(c_allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"names\":[") catch return;
    for (header, 0..) |name, i| {
        if (i > 0) w.writeByte(',') catch return;
        jsonEscapedString(w, name);
    }
    w.writeAll("],\"rows\":[") catch return;
    const items = tk.getSorted();
    for (items, 0..) |entry, i| {
        if (i > 0) w.writeByte(',') catch return;
        w.writeByte('[') catch return;
        for (entry.row.fields, 0..) |f, j| {
            if (j > 0) w.writeByte(',') catch return;
            jsonEscapedString(w, f);
        }
        w.writeByte(']') catch return;
    }
    w.writeAll("],\"keys\":[") catch return;
    for (items, 0..) |entry, i| {
        if (i > 0) w.writeByte(',') catch return;
        w.print("{d}", .{entry.key}) catch return;
    }
    w.writeAll("]}") catch return;
    out.json = aw.toOwnedSlice() catch return;
}

fn napiTopk(env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
    const path = getStringArg(env, info, 0, c_allocator) catch return napiFail(env, "topkJson(path, column, k): path required");
    defer c_allocator.free(path);
    const column = getStringArg(env, info, 1, c_allocator) catch return napiFail(env, "topkJson(path, column, k): column required");
    defer c_allocator.free(column);
    // Sign-checked before the cast, the same way `limit` is everywhere
    // else in this file: @intCast of a negative i64 straight from JS is a
    // panic in a safety-checked build and a wrapped, enormous usize in
    // ReleaseFast — `topkJson(path, col, -1)` reached scan.topK() as a
    // ~2^64 k and took the whole Node process down either way.
    const k_arg = getIntArg(env, info, 2, i64, 10);
    if (k_arg < 0) return napiFail(env, "topkJson(path, column, k): k must not be negative");
    const k: usize = @intCast(k_arg);
    const where = getOptionalStringArg(env, info, 3, c_allocator) catch null;
    defer if (where) |w| c_allocator.free(w);
    const descending = getBoolArg(env, info, 4, true);

    var result = RowsResult{};
    runOnWorkerStack(topkWork, .{ path, column, k, where, descending, &result });
    if (result.err) |e| return failErr(env, e);
    defer c_allocator.free(result.json);
    return napiString(env, result.json);
}

// ── orderBy ──────────────────────────────────────────────────────────

fn orderByWork(path: [:0]const u8, column_name: [:0]const u8, where: ?[:0]const u8, descending: bool, out: *RowsResult) void {
    const header = probeHeader(c_allocator, path) catch |e| {
        out.err = e;
        return;
    };
    defer freeHeader(c_allocator, header);

    const column = resolveColumn(header, column_name) catch |e| {
        out.err = e;
        return;
    };

    var predicates: []Predicate = &.{};
    defer if (predicates.len > 0) freePredicates(c_allocator, predicates);
    if (where) |w| {
        predicates = parseWhereString(c_allocator, header, w) catch |e| {
            out.err = e;
            return;
        };
    }

    var q = Query.open(c_allocator, path, .{ .where = predicates }) catch |e| {
        out.err = e;
        return;
    };
    defer q.deinit();
    var ordered = scan.orderBy(c_allocator, &q, column, descending) catch |e| {
        out.err = e;
        return;
    };
    defer ordered.deinit();

    var aw = std.io.Writer.Allocating.init(c_allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"names\":[") catch return;
    for (header, 0..) |name, i| {
        if (i > 0) w.writeByte(',') catch return;
        jsonEscapedString(w, name);
    }
    w.writeAll("],\"rows\":[") catch return;
    for (ordered.rows, 0..) |row, i| {
        if (i > 0) w.writeByte(',') catch return;
        w.writeByte('[') catch return;
        for (row.fields, 0..) |f, j| {
            if (j > 0) w.writeByte(',') catch return;
            jsonEscapedString(w, f);
        }
        w.writeByte(']') catch return;
    }
    w.writeAll("]}") catch return;
    out.json = aw.toOwnedSlice() catch return;
}

fn napiOrderBy(env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
    const path = getStringArg(env, info, 0, c_allocator) catch return napiFail(env, "orderByJson(path, column): path required");
    defer c_allocator.free(path);
    const column = getStringArg(env, info, 1, c_allocator) catch return napiFail(env, "orderByJson(path, column): column required");
    defer c_allocator.free(column);
    const where = getOptionalStringArg(env, info, 2, c_allocator) catch null;
    defer if (where) |w| c_allocator.free(w);
    const descending = getBoolArg(env, info, 3, false);

    var result = RowsResult{};
    runOnWorkerStack(orderByWork, .{ path, column, where, descending, &result });
    if (result.err) |e| return failErr(env, e);
    defer c_allocator.free(result.json);
    return napiString(env, result.json);
}

// ── streaming scan (open/next/close) ────────────────────────────────
// Handle = the Query's heap address as a plain JS number. Real
// pointers fit comfortably in JS's 53-bit safe-integer range on every
// platform this runs on. Explicit close() required — same contract
// the C ABI's own scanio_open/next/close already has; no finalizer
// safety net, matching that existing convention rather than inventing
// a different lifecycle rule for this one binding.

const OpenScanResult = struct {
    handle: i64 = 0,
    names_json: []const u8 = "",
    err: ?anyerror = null,
};

const ScanHandle = struct {
    query: Query,
    header: [][]const u8,
    // Query.open() stores these as bare slice references, not copies
    // (see query.zig: `.columns = options.columns, .where = options.where`)
    // — they must outlive the Query and be freed alongside it, not right
    // after open() returns the way the single-shot functions above do.
    predicates: []Predicate,
    columns: ?[]usize,
    /// Set for the duration of a nextRowJson() call. Both flags are
    /// guarded by handle_registry_mutex, never touched outside it.
    in_use: bool = false,
    /// closeScan() came in while in_use — the in-flight nextRowJson()
    /// destroys the handle on its way out instead.
    close_requested: bool = false,
};

/// Registry of open scan handles, keyed by a small monotonic ID — NOT
/// the raw pointer address. A raw pointer exposed to JS as a plain
/// number is an arbitrary-memory-dereference risk the moment a caller
/// passes a stale, garbage, or off-by-one handle value: nextRowJson()/
/// closeScan() would `@ptrFromInt` it and read/write through it with
/// zero validation. Looking the ID up here first means an invalid
/// handle fails with a normal JS error instead of a native crash or
/// memory corruption. Mutex guards it because N-API addons can be
/// loaded into `worker_threads`, not just the main JS thread — this
/// registry has no reason to assume single-threaded access even though
/// today's callers happen to be single-threaded.
var handle_registry: std.AutoHashMapUnmanaged(u64, *ScanHandle) = .{};
var handle_registry_mutex: std.Thread.Mutex = .{};
var next_handle_id: u64 = 1;

fn registerHandle(handle: *ScanHandle) !u64 {
    handle_registry_mutex.lock();
    defer handle_registry_mutex.unlock();
    const id = next_handle_id;
    next_handle_id += 1;
    try handle_registry.put(c_allocator, id, handle);
    return id;
}

/// Frees everything a ScanHandle owns, including the handle itself.
/// Never call it on a handle still reachable through the registry.
fn destroyHandle(handle: *ScanHandle) void {
    handle.query.deinit();
    freeHeader(c_allocator, handle.header);
    if (handle.predicates.len > 0) freePredicates(c_allocator, handle.predicates);
    if (handle.columns) |c| c_allocator.free(c);
    c_allocator.destroy(handle);
}

/// Looks a handle up and marks it busy, so a concurrent closeScan()
/// cannot free it out from under the caller.
///
/// The mutex used to guard the lookup ONLY, which left a real
/// use-after-free between the two calls that are supposed to be safe
/// under `worker_threads` (the whole reason this registry exists):
/// thread A gets the pointer from the map, thread B closes the same
/// handle and frees it, then thread A dereferences freed memory.
/// Returns null for an unknown, already-closed, or already-busy handle —
/// all three are caller errors that must surface as a JS exception
/// rather than as memory corruption.
fn acquireHandle(id: u64) ?*ScanHandle {
    handle_registry_mutex.lock();
    defer handle_registry_mutex.unlock();
    const handle = handle_registry.get(id) orelse return null;
    if (handle.in_use) return null;
    handle.in_use = true;
    return handle;
}

/// Ends the borrow started by acquireHandle(), destroying the handle if
/// a closeScan() arrived in the meantime.
fn releaseHandle(handle: *ScanHandle) void {
    handle_registry_mutex.lock();
    handle.in_use = false;
    const now_dead = handle.close_requested;
    handle_registry_mutex.unlock();
    if (now_dead) destroyHandle(handle);
}

/// Removes a handle from the registry — the ID is invalid from here on
/// either way, which is what makes double-close a silent no-op. Returns
/// the handle to free, or null if an in-flight nextRowJson() still holds
/// it (that call frees it when it releases) or the ID was never valid.
fn unregisterHandle(id: u64) ?*ScanHandle {
    handle_registry_mutex.lock();
    defer handle_registry_mutex.unlock();
    const entry = handle_registry.fetchRemove(id) orelse return null;
    if (entry.value.in_use) {
        entry.value.close_requested = true;
        return null;
    }
    return entry.value;
}

fn openScanWork(path: [:0]const u8, where: ?[:0]const u8, columns_json: ?[:0]const u8, limit: i64, out: *OpenScanResult) void {
    const header = probeHeader(c_allocator, path) catch |e| {
        out.err = e;
        return;
    };

    var predicates: []Predicate = &.{};
    if (where) |w| {
        predicates = parseWhereString(c_allocator, header, w) catch |e| {
            freeHeader(c_allocator, header);
            out.err = e;
            return;
        };
    }
    const columns = parseColumnsJson(c_allocator, header, columns_json) catch |e| {
        freeHeader(c_allocator, header);
        if (predicates.len > 0) freePredicates(c_allocator, predicates);
        out.err = e;
        return;
    };

    const q = Query.open(c_allocator, path, .{
        .where = predicates,
        .columns = columns,
        .limit = if (limit < 0) null else @intCast(limit),
    }) catch |e| {
        freeHeader(c_allocator, header);
        if (predicates.len > 0) freePredicates(c_allocator, predicates);
        if (columns) |c| c_allocator.free(c);
        out.err = e;
        return;
    };
    // predicates/columns are owned by `q` internally where it needs
    // them for the scan's lifetime — NOT freed here, freed in
    // closeScanWork alongside the rest of the handle.

    // Everything from here on has to undo `q` too, not just the header
    // and predicates: every failure path below used to return with the
    // Query — and the open file handle inside it — still live.
    var q_mut = q;
    var opened_ok = false;
    defer if (!opened_ok) {
        q_mut.deinit();
        freeHeader(c_allocator, header);
        if (predicates.len > 0) freePredicates(c_allocator, predicates);
        if (columns) |c| c_allocator.free(c);
    };

    const proj = columns orelse blk: {
        const idx = c_allocator.alloc(usize, header.len) catch {
            out.err = error.OutOfMemory;
            return;
        };
        for (idx, 0..) |*v, i| v.* = i;
        break :blk idx;
    };
    defer if (columns == null) c_allocator.free(proj);

    var aw = std.io.Writer.Allocating.init(c_allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeByte('[') catch {
        out.err = error.OutOfMemory;
        return;
    };
    for (proj, 0..) |ci, i| {
        if (i > 0) w.writeByte(',') catch {
            out.err = error.OutOfMemory;
            return;
        };
        jsonEscapedString(w, header[ci]);
    }
    w.writeByte(']') catch {
        out.err = error.OutOfMemory;
        return;
    };
    const names_json = aw.toOwnedSlice() catch {
        out.err = error.OutOfMemory;
        return;
    };
    errdefer c_allocator.free(names_json);

    const handle = c_allocator.create(ScanHandle) catch {
        c_allocator.free(names_json);
        out.err = error.OutOfMemory;
        return;
    };
    handle.* = .{ .query = q_mut, .header = header, .predicates = predicates, .columns = columns };
    const id = registerHandle(handle) catch {
        destroyHandle(handle);
        c_allocator.free(names_json);
        // The handle owns (and just freed) all of it — don't let the
        // defer above free the same memory a second time.
        opened_ok = true;
        out.err = error.OutOfMemory;
        return;
    };
    // Ownership has moved into the registered handle; closeScan frees it.
    opened_ok = true;
    out.names_json = names_json;
    out.handle = @intCast(id);
}

fn napiOpenScan(env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
    const path = getStringArg(env, info, 0, c_allocator) catch return napiFail(env, "openScan(path): path required");
    defer c_allocator.free(path);
    const where = getOptionalStringArg(env, info, 1, c_allocator) catch null;
    defer if (where) |w| c_allocator.free(w);
    const columns_json = getOptionalStringArg(env, info, 2, c_allocator) catch null;
    defer if (columns_json) |c| c_allocator.free(c);
    const limit = getIntArg(env, info, 3, i64, -1);

    var result = OpenScanResult{};
    runOnWorkerStack(openScanWork, .{ path, where, columns_json, limit, &result });
    if (result.err) |e| return failErr(env, e);

    var obj: napi.napi_value = undefined;
    _ = napi.napi_create_object(env, &obj);
    _ = napi.napi_set_named_property(env, obj, "handle", napiInt64(env, result.handle));
    _ = napi.napi_set_named_property(env, obj, "namesJson", napiString(env, result.names_json));
    c_allocator.free(result.names_json);
    return obj;
}

fn napiNextRow(env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
    const handle_id = getIntArg(env, info, 0, i64, 0);
    if (handle_id <= 0) return napiFail(env, "nextRowJson(handle): invalid handle");
    const handle = acquireHandle(@intCast(handle_id)) orelse
        return napiFail(env, "nextRowJson(handle): unknown, already-closed, or concurrently-in-use handle");
    defer releaseHandle(handle);

    const row = handle.query.next() catch |e| return failErr(env, e);
    const r = row orelse {
        var null_val: napi.napi_value = undefined;
        _ = napi.napi_get_null(env, &null_val);
        return null_val;
    };

    var aw = std.io.Writer.Allocating.init(c_allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeByte('[') catch return napiFail(env, "out of memory");
    for (r.fields, 0..) |f, i| {
        if (i > 0) w.writeByte(',') catch return napiFail(env, "out of memory");
        jsonEscapedString(w, f);
    }
    w.writeByte(']') catch return napiFail(env, "out of memory");
    const json = aw.toOwnedSlice() catch return napiFail(env, "out of memory");
    defer c_allocator.free(json);
    return napiString(env, json);
}

fn napiCloseScan(env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
    const handle_id = getIntArg(env, info, 0, i64, 0);
    var undef: napi.napi_value = undefined;
    _ = napi.napi_get_undefined(env, &undef);
    if (handle_id <= 0) return undef;
    // Double-close is a silent no-op, not an error — unregisterHandle()
    // removes the entry, so a second close() on the same ID finds
    // nothing and returns early, same as the old raw-pointer version's
    // implicit behavior (a double-free there was instead a real bug).
    const handle = unregisterHandle(@intCast(handle_id)) orelse return undef;
    destroyHandle(handle);
    return undef;
}

// ── Module registration ──────────────────────────────────────────────

fn prop(name: [*:0]const u8, method: napi.napi_callback) napi.napi_property_descriptor {
    return .{
        .utf8name = name,
        .name = null,
        .method = method,
        .getter = null,
        .setter = null,
        .value = null,
        .attributes = napi.napi_default,
        .data = null,
    };
}

export fn napi_register_module_v1(env: napi.napi_env, exports: napi.napi_value) callconv(.c) napi.napi_value {
    const props = [_]napi.napi_property_descriptor{
        prop("schemaJson", napiSchema),
        prop("countJson", napiCount),
        prop("aggregateJson", napiAggregate),
        prop("scanArrayJson", napiScanArray),
        prop("topkJson", napiTopk),
        prop("orderByJson", napiOrderBy),
        prop("openScan", napiOpenScan),
        prop("nextRowJson", napiNextRow),
        prop("closeScan", napiCloseScan),
    };
    _ = napi.napi_define_properties(env, exports, props.len, &props);
    return exports;
}
