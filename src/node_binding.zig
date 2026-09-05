//! Node.js N-API binding for libscanio — replaces the koffi-based
//! `node/` package, not a second binding alongside it.
//!
//! Why: koffi's Windows FFI dispatch crashes on `scanio_open()` (exit
//! code 5, zero output) for a call shape isolated down to "2 arguments,
//! one a pointer, void* return" — confirmed NOT a libscanio bug (the
//! identical shape passes cleanly through Python's ctypes on the same
//! Windows runner), confirmed NOT fixed by upgrading koffi to its
//! latest version, confirmed NOT about struct marshaling (a bare
//! `scanio_open(path, null)` with zero structs involved crashes the
//! same way). See ROADMAP.md's M5b entry for the full investigation.
//! That bug lives inside koffi's own Windows trampoline generation —
//! out of this project's reach to patch. An N-API addon compiled
//! directly against Node's own `node_api.h` has no such dynamic-FFI
//! layer at all — this file calls the SAME Zig core (`Query`,
//! `aggregate`, `topK`, `orderBy`, `parallelScanColumnar`) every other
//! binding uses, directly, not through c_api.zig's C-struct boundary —
//! there is no struct marshaling to have a bug in at all, in either
//! language.
//!
//! Every exported function is JSON/plain-string in, JSON/plain-value
//! out (same "text in, text out" shape csvql's own N-API addon uses,
//! this project's sibling and the source of this whole pattern) —
//! WHERE clauses are parsed HERE in Zig (parseWhereString below),
//! mirroring the same "col OP val [AND col OP val ...]" / "col IN
//! (a,b,c)" grammar the koffi-based node/lib/index.js parsed in JS,
//! now done once, in one language, reusable by any future binding.
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

// ── WHERE-string parsing ────────────────────────────────────────────
// "col OP val [AND col OP val ...]" / "col IN (a, b, c)" — same grammar
// the koffi-based JS binding parsed with regex; ported mechanically,
// not redesigned.

fn resolveColumn(header: []const []const u8, name: []const u8) !usize {
    for (header, 0..) |h, i| {
        if (std.mem.eql(u8, h, name)) return i;
    }
    return error.UnknownColumn;
}

fn opFromString(s: []const u8) ?Op {
    if (std.mem.eql(u8, s, "=")) return .eq;
    if (std.mem.eql(u8, s, "!=")) return .neq;
    if (std.mem.eql(u8, s, ">=")) return .gte;
    if (std.mem.eql(u8, s, "<=")) return .lte;
    if (std.mem.eql(u8, s, ">")) return .gt;
    if (std.mem.eql(u8, s, "<")) return .lt;
    return null;
}

/// Parses one AND-joined WHERE string into a predicate list. Column
/// names resolved against `header`. Returned slice AND every IN
/// predicate's owned values slice are allocated with `allocator` —
/// caller frees both (see freePredicates below).
fn parseWhereString(allocator: std.mem.Allocator, header: []const []const u8, where: []const u8) ![]Predicate {
    var predicates: std.ArrayListUnmanaged(Predicate) = .{};
    errdefer predicates.deinit(allocator);

    var it = std.mem.splitSequence(u8, where, " AND ");
    while (it.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (part.len == 0) continue;

        // "col IN (a, b, c)"
        if (std.mem.indexOf(u8, part, " IN ")) |in_pos| {
            const col_name = std.mem.trim(u8, part[0..in_pos], " \t");
            const rest = std.mem.trim(u8, part[in_pos + 4 ..], " \t");
            if (rest.len < 2 or rest[0] != '(' or rest[rest.len - 1] != ')') return error.InvalidWhere;
            const inner = rest[1 .. rest.len - 1];
            const col = try resolveColumn(header, col_name);

            var vals: std.ArrayListUnmanaged([]const u8) = .{};
            defer vals.deinit(allocator);
            var vit = std.mem.splitScalar(u8, inner, ',');
            while (vit.next()) |v| {
                const trimmed = std.mem.trim(u8, v, " \t");
                if (trimmed.len > 0) try vals.append(allocator, try allocator.dupe(u8, trimmed));
            }
            if (vals.items.len == 0) return error.InvalidWhere;
            const owned_vals = try vals.toOwnedSlice(allocator);
            try predicates.append(allocator, Predicate.initIn(col, owned_vals));
            continue;
        }

        // "col OP val" — find the operator by scanning for one of the
        // known symbols; longest match first (>= before >, etc.).
        const ops = [_][]const u8{ ">=", "<=", "!=", "=", ">", "<" };
        var found_op: ?[]const u8 = null;
        var op_pos: usize = 0;
        for (ops) |op_str| {
            if (std.mem.indexOf(u8, part, op_str)) |pos| {
                if (found_op == null or pos < op_pos) {
                    found_op = op_str;
                    op_pos = pos;
                }
            }
        }
        const op_str = found_op orelse return error.InvalidWhere;
        const col_name = std.mem.trim(u8, part[0..op_pos], " \t");
        const val = std.mem.trim(u8, part[op_pos + op_str.len ..], " \t");
        const col = try resolveColumn(header, col_name);
        const op = opFromString(op_str) orelse return error.InvalidWhere;
        try predicates.append(allocator, Predicate.init(col, op, try allocator.dupe(u8, val)));
    }
    return predicates.toOwnedSlice(allocator);
}

fn freePredicates(allocator: std.mem.Allocator, predicates: []Predicate) void {
    for (predicates) |p| {
        if (p.op == .in_list) {
            for (p.values) |v| allocator.free(@constCast(v));
            allocator.free(@constCast(p.values));
        } else {
            allocator.free(@constCast(p.value));
        }
    }
    allocator.free(predicates);
}

/// Resolves a JSON array of column-name strings into indices against
/// `header`. Null input (no projection requested) returns null.
fn parseColumnsJson(allocator: std.mem.Allocator, header: []const []const u8, columns_json: ?[]const u8) !?[]usize {
    const cj = columns_json orelse return null;
    if (cj.len == 0) return null;
    const parsed = try std.json.parseFromSlice([]const []const u8, allocator, cj, .{});
    defer parsed.deinit();
    var out = try allocator.alloc(usize, parsed.value.len);
    for (parsed.value, 0..) |name, i| out[i] = try resolveColumn(header, name);
    return out;
}

/// Opens a throwaway Query (no predicates) just to read the header,
/// then closes it — same two-open pattern every existing binding
/// already uses (resolve names/predicates against a probe, then open
/// for real with them applied).
fn probeHeader(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var probe = try Query.open(allocator, path, .{});
    defer probe.deinit();
    const h = probe.header();
    const out = try allocator.alloc([]const u8, h.len);
    for (h, 0..) |name, i| out[i] = try allocator.dupe(u8, name);
    return out;
}

fn freeHeader(allocator: std.mem.Allocator, header: [][]const u8) void {
    for (header) |h| allocator.free(@constCast(h));
    allocator.free(header);
}

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

fn getStringArg(env: napi.napi_env, info: napi.napi_callback_info, index: usize, allocator: std.mem.Allocator) ![:0]u8 {
    var argc: usize = 6;
    var args: [6]napi.napi_value = undefined;
    _ = napi.napi_get_cb_info(env, info, &argc, &args, null, null);
    if (argc <= index) return error.MissingArgument;

    var value_type: napi.napi_valuetype = undefined;
    _ = napi.napi_typeof(env, args[index], &value_type);
    if (value_type == napi.napi_null or value_type == napi.napi_undefined) return error.MissingArgument;

    var len: usize = 0;
    _ = napi.napi_get_value_string_utf8(env, args[index], null, 0, &len);
    const buf = try allocator.allocSentinel(u8, len, 0);
    _ = napi.napi_get_value_string_utf8(env, args[index], buf.ptr, len + 1, &len);
    return buf;
}

fn getOptionalStringArg(env: napi.napi_env, info: napi.napi_callback_info, index: usize, allocator: std.mem.Allocator) !?[:0]u8 {
    return getStringArg(env, info, index, allocator) catch |e| switch (e) {
        error.MissingArgument => null,
        else => return e,
    };
}

fn getIntArg(env: napi.napi_env, info: napi.napi_callback_info, index: usize, comptime T: type, default: T) T {
    var argc: usize = 6;
    var args: [6]napi.napi_value = undefined;
    _ = napi.napi_get_cb_info(env, info, &argc, &args, null, null);
    if (argc <= index) return default;
    var value_type: napi.napi_valuetype = undefined;
    _ = napi.napi_typeof(env, args[index], &value_type);
    if (value_type == napi.napi_null or value_type == napi.napi_undefined) return default;
    var v: i64 = 0;
    _ = napi.napi_get_value_int64(env, args[index], &v);
    return @intCast(v);
}

fn getBoolArg(env: napi.napi_env, info: napi.napi_callback_info, index: usize, default: bool) bool {
    var argc: usize = 6;
    var args: [6]napi.napi_value = undefined;
    _ = napi.napi_get_cb_info(env, info, &argc, &args, null, null);
    if (argc <= index) return default;
    var value_type: napi.napi_valuetype = undefined;
    _ = napi.napi_typeof(env, args[index], &value_type);
    if (value_type == napi.napi_null or value_type == napi.napi_undefined) return default;
    var v: bool = default;
    _ = napi.napi_get_value_bool(env, args[index], &v);
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

    var q = Query.open(c_allocator, path, .{ .where = predicates }) catch |e| {
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

    var q = Query.open(c_allocator, path, .{ .where = predicates }) catch |e| {
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
    const k: usize = @intCast(getIntArg(env, info, 2, i64, 10));
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
};

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

    const proj = columns orelse blk: {
        const idx = c_allocator.alloc(usize, header.len) catch {
            out.err = error.OutOfMemory;
            return;
        };
        for (idx, 0..) |*v, i| v.* = i;
        break :blk idx;
    };

    var aw = std.io.Writer.Allocating.init(c_allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeByte('[') catch return;
    for (proj, 0..) |ci, i| {
        if (i > 0) w.writeByte(',') catch return;
        jsonEscapedString(w, header[ci]);
    }
    w.writeByte(']') catch return;
    if (columns == null) c_allocator.free(proj);
    out.names_json = aw.toOwnedSlice() catch return;

    const handle = c_allocator.create(ScanHandle) catch {
        out.err = error.OutOfMemory;
        return;
    };
    handle.* = .{ .query = q, .header = header, .predicates = predicates, .columns = columns };
    out.handle = @intCast(@intFromPtr(handle));
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
    const handle_addr = getIntArg(env, info, 0, i64, 0);
    if (handle_addr == 0) return napiFail(env, "nextRowJson(handle): invalid handle");
    const handle: *ScanHandle = @ptrFromInt(@as(usize, @intCast(handle_addr)));

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
    const handle_addr = getIntArg(env, info, 0, i64, 0);
    var undef: napi.napi_value = undefined;
    _ = napi.napi_get_undefined(env, &undef);
    if (handle_addr == 0) return undef;
    const handle: *ScanHandle = @ptrFromInt(@as(usize, @intCast(handle_addr)));
    handle.query.deinit();
    freeHeader(c_allocator, handle.header);
    if (handle.predicates.len > 0) freePredicates(c_allocator, handle.predicates);
    if (handle.columns) |c| c_allocator.free(c);
    c_allocator.destroy(handle);
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
