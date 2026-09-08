//! Private native bridge for the CPython extension. No Python dependency.
//! Slices passed to emit are borrowed only until the callback returns.
const std = @import("std");
const scan = @import("scanio");
const Slice = extern struct { ptr: [*]const u8, len: usize };
const Failure = extern struct { column: usize, name: Slice, rule: Slice, value: Slice };
const Emit = *const fn (?*anyopaque, [*]const Slice, usize, [*]const Failure, usize) callconv(.c) c_int;
const Poll = *const fn (?*anyopaque) callconv(.c) c_int;
fn slice(s: []const u8) Slice {
    return .{ .ptr = s.ptr, .len = s.len };
}

fn run(input: []const u8, schema: []const u8, format: c_int, full: bool, ctx: ?*anyopaque, emit: Emit, poll: Poll) !bool {
    const allocator = std.heap.c_allocator;
    var v = if (format == 0) try scan.Validator.openJson(allocator, input, schema) else try scan.Validator.fromBytesJson(allocator, input, if (format == 1) .csv else .ndjson, schema);
    defer v.deinit();
    for (v.header()) |name| if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidUtf8;
    var fields: std.ArrayListUnmanaged(Slice) = .{};
    defer fields.deinit(allocator);
    var errors: std.ArrayListUnmanaged(Failure) = .{};
    defer errors.deinit(allocator);
    while (try v.nextOutcome(full)) |item| {
        if (v.row_number % 1024 == 0 and poll(ctx) != 0) return error.CallbackFailed;
        if (!full) {
            if (v.rows_invalid > 0) return false;
            continue;
        }
        if (item.isValid()) continue;
        fields.clearRetainingCapacity();
        errors.clearRetainingCapacity();
        for (item.row.fields) |field| try fields.append(allocator, slice(field));
        for (item.errors) |err| try errors.append(allocator, .{
            .column = err.column orelse std.math.maxInt(usize),
            .name = slice(err.column_name),
            .rule = slice(err.kind.name()),
            .value = slice(err.value),
        });
        if (emit(ctx, fields.items.ptr, fields.items.len, errors.items.ptr, errors.items.len) != 0) return error.CallbackFailed;
    }
    return v.rows_invalid == 0;
}

// 1 valid, 0 invalid, -1 native failure, -2 callback failure (Python exception).
pub export fn scanio_python_validate(input: [*]const u8, input_len: usize, schema: [*]const u8, schema_len: usize, format: c_int, full: c_int, ctx: ?*anyopaque, emit: Emit, poll: Poll, error_buf: [*]u8, error_len: usize) c_int {
    const valid = run(input[0..input_len], schema[0..schema_len], format, full != 0, ctx, emit, poll) catch |err| {
        if (err == error.CallbackFailed) return -2;
        _ = std.fmt.bufPrintZ(error_buf[0..error_len], "{s}", .{@errorName(err)}) catch {};
        return -1;
    };
    return if (valid) 1 else 0;
}

pub export fn scanio_python_build_mode() [*:0]const u8 {
    return @tagName(@import("builtin").mode);
}
