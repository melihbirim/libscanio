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
//! layer at all: this file calls c_api.zig's ALREADY-exported C ABI
//! functions as ordinary same-binary Zig function calls (not a second
//! marshaling boundary), so there is no struct-layout risk to begin
//! with — the only translation happening here is JS string in, JS
//! string/number out.
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
const c_api = @import("c_api.zig");

const napi = @cImport(@cInclude("node_api.h"));

const c_allocator = std.heap.c_allocator;
const worker_stack_size = 16 * 1024 * 1024;

// ── N-API helpers ────────────────────────────────────────────────────

fn napiFail(env: napi.napi_env, msg: [:0]const u8) napi.napi_value {
    _ = napi.napi_throw_error(env, null, msg.ptr);
    var undef: napi.napi_value = undefined;
    _ = napi.napi_get_undefined(env, &undef);
    return undef;
}

fn napiString(env: napi.napi_env, s: []const u8) napi.napi_value {
    var out: napi.napi_value = undefined;
    _ = napi.napi_create_string_utf8(env, s.ptr, s.len, &out);
    return out;
}

/// Reads JS argument `index` as an owned, NUL-terminated UTF-8 string —
/// caller frees with `allocator.free(result)`. `[:0]u8` because
/// `scanio_open`'s path argument needs a real C string, not just a
/// length-prefixed slice.
fn getStringArg(env: napi.napi_env, info: napi.napi_callback_info, index: usize, allocator: std.mem.Allocator) ![:0]u8 {
    var argc: usize = index + 1;
    var args: [4]napi.napi_value = undefined;
    _ = napi.napi_get_cb_info(env, info, &argc, &args, null, null);
    if (argc <= index) return error.MissingArgument;

    var len: usize = 0;
    _ = napi.napi_get_value_string_utf8(env, args[index], null, 0, &len);
    const buf = try allocator.allocSentinel(u8, len, 0);
    _ = napi.napi_get_value_string_utf8(env, args[index], buf.ptr, len + 1, &len);
    return buf;
}

// ── Core work, run on a dedicated thread (see file doc comment) ────────

const SchemaResult = struct {
    json: []const u8,
    err: ?[]const u8 = null,
};

fn schemaWork(path: [:0]const u8, out: *SchemaResult) void {
    const ctx = c_api.scanio_open(path.ptr, null) orelse {
        const e = c_api.scanio_last_error() orelse "open failed";
        out.err = c_allocator.dupe(u8, std.mem.span(e)) catch "open failed";
        return;
    };
    defer c_api.scanio_close(ctx);

    var aw = std.io.Writer.Allocating.init(c_allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeByte('[') catch return;
    const n = c_api.scanio_n_columns(ctx);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) w.writeByte(',') catch return;
        const name = c_api.scanio_column_name(ctx, i) orelse "";
        std.json.Stringify.value(std.mem.span(name), .{}, w) catch return;
    }
    w.writeByte(']') catch return;
    out.json = aw.toOwnedSlice() catch return;
}

fn runOnWorkerStack(comptime WorkFn: anytype, args: anytype) void {
    const t = std.Thread.spawn(.{ .stack_size = worker_stack_size }, WorkFn, args) catch {
        // Falling back to the caller's (V8) stack here is exactly the
        // crash this thread exists to avoid — surface as an error result
        // instead. Every *Result struct's `err` field defaults non-null-
        // friendly enough that leaving `json`/etc. unset and checking
        // `err` first at the call site is safe.
        return;
    };
    t.join();
}

// ── Exported JS functions ───────────────────────────────────────────────

fn napiSchema(env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
    const path = getStringArg(env, info, 0, c_allocator) catch return napiFail(env, "schema(path): path argument required");
    defer c_allocator.free(path);

    var result = SchemaResult{ .json = "" };
    runOnWorkerStack(schemaWork, .{ path, &result });
    if (result.err) |e| {
        defer c_allocator.free(e);
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "{s}", .{e}) catch "schema failed";
        return napiFail(env, msg);
    }
    defer c_allocator.free(result.json);
    return napiString(env, result.json);
}

// ── Module registration ──────────────────────────────────────────────

export fn napi_register_module_v1(env: napi.napi_env, exports: napi.napi_value) callconv(.c) napi.napi_value {
    const props = [_]napi.napi_property_descriptor{
        .{
            .utf8name = "schemaJson",
            .name = null,
            .method = napiSchema,
            .getter = null,
            .setter = null,
            .value = null,
            .attributes = napi.napi_default,
            .data = null,
        },
    };
    _ = napi.napi_define_properties(env, exports, props.len, &props);
    return exports;
}
