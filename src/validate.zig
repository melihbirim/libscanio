//! Import validation: walk a file once and say, per row, whether it can
//! be loaded — and if not, exactly which cell broke which rule.
//!
//! ## Why this is not just scan() plus a WHERE clause
//!
//! A WHERE clause answers "which rows do I want". An importer asks the
//! opposite question — "which rows can I not take, and why" — and needs
//! the reason, per cell, to put in front of a human. Every rule here is
//! evaluated in Zig rather than in each binding, so the Python client,
//! the Node client and the CLI cannot drift into three slightly
//! different definitions of "is this an integer".
//!
//! ## Bounded memory, like everything else here
//!
//! `Validator` streams: it holds one row at a time and the errors for
//! that row, nothing more, so a 40GB import costs the same memory as a
//! 40KB one. `validate()` is the convenience wrapper that drains it into
//! a summary, and it is bounded too — it counts every error but stores
//! only the first `max_errors` of them. A file where every row is broken
//! must not turn a validation pass into an out-of-memory crash; that is
//! precisely the file you most want a report about.
//!
//! ## What is deliberately absent
//!
//! Uniqueness ("no duplicate ids") and referential checks. Both need
//! state proportional to the file — a set of every value seen — which is
//! the one thing this library promises not to build. They belong in the
//! database doing the import, which already has the index.
const std = @import("std");
const Allocator = std.mem.Allocator;
const query_mod = @import("query.zig");
const Query = query_mod.Query;
const Row = @import("root.zig").Row;

pub const ValidateError = error{
    UnknownColumn,
    BadSchema,
} || Allocator.Error;

/// The type vocabulary, matching `describe()`'s inferred types exactly
/// so a schema drafted from an inferred one validates the file it was
/// drafted from.
pub const ColumnType = enum {
    any,
    integer,
    float,
    boolean,
    datetime,
    string,

    pub fn parse(s: []const u8) ?ColumnType {
        return std.meta.stringToEnum(ColumnType, s);
    }
};

pub const ErrorKind = enum {
    // Structural — about the row's shape, not any one cell. Kept
    // separate from rule failures because they mean something different
    // to an importer: a short row is usually a broken file, while a bad
    // value is usually a broken record.
    too_few_fields,
    too_many_fields,
    // Rule failures — about one cell.
    missing_required,
    bad_type,
    below_min,
    above_max,
    too_short,
    too_long,
    not_in_set,

    pub fn isStructural(self: ErrorKind) bool {
        return self == .too_few_fields or self == .too_many_fields;
    }

    /// Stable machine-readable name, shared by every binding's output.
    pub fn name(self: ErrorKind) []const u8 {
        return @tagName(self);
    }
};

pub const n_error_kinds = @typeInfo(ErrorKind).@"enum".fields.len;

/// Every rule that can be attached to one column. All optional: a rule
/// left null is not checked, so `{"required": true}` alone is a valid
/// and useful schema entry.
pub const Rule = struct {
    column: usize,
    /// Borrowed from the header — the Validator outlives no longer than
    /// the Query whose header this points into.
    name: []const u8,
    type: ColumnType = .any,
    required: bool = false,
    min: ?f64 = null,
    max: ?f64 = null,
    min_len: ?usize = null,
    max_len: ?usize = null,
    one_of: []const []const u8 = &.{},
    /// Compiled by parseSchema for large sets; storage belongs to the
    /// schema arena. Reparse the schema to change its membership rules.
    one_of_index: ?std.StringHashMapUnmanaged(void) = null,
};

/// One failure. `column` is null for a structural error, which is about
/// the row rather than any single cell.
pub const RowError = struct {
    row: u64,
    column: ?usize,
    column_name: []const u8,
    kind: ErrorKind,
    /// The offending cell, borrowed from the scan buffer — valid only
    /// until the next `Validator.next()`. `Report` copies what it keeps.
    value: []const u8,
};

/// The schema: rules plus how wide a row is expected to be.
pub const Schema = struct {
    allocator: Allocator,
    rules: []Rule,
    /// Number of header columns, so a row's width can be checked without
    /// re-reading the header.
    n_columns: usize,
    /// Owns every string the rules borrow from the parsed JSON (one_of
    /// values), so a schema outlives the JSON text it came from.
    strings: std.heap.ArenaAllocator,

    pub fn deinit(self: *Schema) void {
        self.allocator.free(self.rules);
        self.strings.deinit();
    }
};

// ── rule evaluation ──────────────────────────────────────────────────

/// Trimmed emptiness, not byte emptiness: a cell of spaces is what a
/// spreadsheet leaves behind when someone clears it, and treating it as
/// present would let blank rows through a `required` check.
fn isBlank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r\n").len == 0;
}

fn isInteger(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return false;
    const body = if (t[0] == '-' or t[0] == '+') t[1..] else t;
    if (body.len == 0) return false;
    for (body) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Surrounding whitespace is never data here. `isBlank`, `isInteger`,
/// `isBoolean` and `isDatetime` all trim, so the numeric checks have to
/// as well: without this, ` 55 ` was a valid `integer` and an invalid
/// `float` in the same file, which is not a rule anyone could have
/// meant. Deliberately local to validation rather than pushed into
/// query.zig's parseNumeric — that one defines what a PREDICATE sees,
/// and widening it would silently change every WHERE, aggregate and
/// sort in the library.
fn numeric(s: []const u8) ?f64 {
    return query_mod.parseNumeric(std.mem.trim(u8, s, " \t"));
}

fn isBoolean(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t");
    return std.ascii.eqlIgnoreCase(t, "true") or std.ascii.eqlIgnoreCase(t, "false");
}

/// ISO-8601-shaped: `YYYY-MM-DD`, optionally followed by `T` or a space
/// and `HH:MM[:SS[.fff]]`, optionally followed by `Z` or `±HH:MM`.
/// Structural plus a real calendar range check — `2024-13-01` is not a
/// date. Deliberately not a full parser: this says "could be loaded as a
/// timestamp", which is the question an importer is asking.
fn isDatetime(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len < 10) return false;
    if (t[4] != '-' or t[7] != '-') return false;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| if (!std.ascii.isDigit(t[i])) return false;
    const month = (t[5] - '0') * 10 + (t[6] - '0');
    const day = (t[8] - '0') * 10 + (t[9] - '0');
    const year = @as(u16, t[0] - '0') * 1000 + @as(u16, t[1] - '0') * 100 +
        @as(u16, t[2] - '0') * 10 + @as(u16, t[3] - '0');
    if (year == 0 or month < 1 or month > 12 or day < 1) return false;
    const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    const max_day = days[month - 1] + @as(u8, if (month == 2 and leap) 1 else 0);
    if (day > max_day) return false;
    if (t.len == 10) return true;

    if (t[10] != 'T' and t[10] != ' ') return false;
    var rest = t[11..];
    if (rest.len < 5) return false;
    if (!std.ascii.isDigit(rest[0]) or !std.ascii.isDigit(rest[1]) or rest[2] != ':') return false;
    if (!std.ascii.isDigit(rest[3]) or !std.ascii.isDigit(rest[4])) return false;
    const hour = (rest[0] - '0') * 10 + (rest[1] - '0');
    const minute = (rest[3] - '0') * 10 + (rest[4] - '0');
    if (hour > 23 or minute > 59) return false;
    rest = rest[5..];

    if (rest.len >= 3 and rest[0] == ':' and std.ascii.isDigit(rest[1]) and std.ascii.isDigit(rest[2])) {
        const second = (rest[1] - '0') * 10 + (rest[2] - '0');
        if (second > 60) return false; // 60 for a leap second
        rest = rest[3..];
        if (rest.len >= 2 and rest[0] == '.') {
            var i: usize = 1;
            while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
            if (i == 1) return false;
            rest = rest[i..];
        }
    }

    if (rest.len == 0) return true;
    if (rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z')) return true;
    if (rest.len == 6 and (rest[0] == '+' or rest[0] == '-')) {
        if (!(std.ascii.isDigit(rest[1]) and std.ascii.isDigit(rest[2]) and rest[3] == ':' and
            std.ascii.isDigit(rest[4]) and std.ascii.isDigit(rest[5]))) return false;
        return (rest[1] - '0') * 10 + (rest[2] - '0') <= 23 and
            (rest[4] - '0') * 10 + (rest[5] - '0') <= 59;
    }
    return false;
}

fn matchesType(t: ColumnType, value: []const u8) bool {
    return switch (t) {
        .any, .string => true,
        .integer => isInteger(value),
        // parseNumeric, not parseFloat: the library's one definition of
        // "a usable number", which excludes the literal text "nan" and
        // "inf" (see query.zig).
        .float => numeric(value) != null,
        .boolean => isBoolean(value),
        .datetime => isDatetime(value),
    };
}

/// Codepoints, not bytes: `max_len: 10` on a name column means ten
/// characters to whoever wrote the schema, and "Zürich" is six.
fn textLength(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

// ── streaming validation ─────────────────────────────────────────────

pub const ValidatedRow = struct {
    /// 1-based, header excluded — the row number a person would point at
    /// in a spreadsheet is this plus one.
    number: u64,
    row: Row,
    /// Empty when the row is clean. Valid only until the next `next()`.
    errors: []const RowError,

    pub fn isValid(self: ValidatedRow) bool {
        return self.errors.len == 0;
    }
};

/// Report mode counts every failure but only constructs retained errors.
/// Streaming mode has no cap and returns every error as before.
const ErrorSink = struct {
    allocator: Allocator,
    errors: *std.ArrayListUnmanaged(RowError),
    row_number: u64,
    counts: ?*[n_error_kinds]u64,
    limit: usize,
    failed: bool = false,

    fn add(self: *ErrorSink, column: ?usize, name: []const u8, kind: ErrorKind, value: []const u8) !void {
        self.failed = true;
        if (self.counts) |counts| counts[@intFromEnum(kind)] += 1;
        if (self.errors.items.len >= self.limit) return;
        try self.errors.append(self.allocator, .{
            .row = self.row_number,
            .column = column,
            .column_name = name,
            .kind = kind,
            .value = value,
        });
    }
};

/// Walks a file row by row, handing back each row with its failures
/// attached. This is the primitive; `validate()` is a summary built on
/// top of it. Streaming is the point: an importer wants to write the
/// good rows to its target and the bad ones to a rejects file as it
/// goes, not after materializing both.
pub const Validator = struct {
    allocator: Allocator,
    query: Query,
    schema: *const Schema,
    owned_schema: ?*Schema = null,
    errors: std.ArrayListUnmanaged(RowError) = .{},
    row_number: u64 = 0,
    rows_valid: u64 = 0,
    rows_invalid: u64 = 0,

    pub fn open(allocator: Allocator, path: []const u8, schema: *const Schema) !Validator {
        return .{
            .allocator = allocator,
            .query = try Query.open(allocator, path, .{}),
            .schema = schema,
        };
    }

    /// Open once, compile against this scanner's header, then continue
    /// from its existing buffered position. Heap ownership survives moves.
    pub fn openJson(allocator: Allocator, path: []const u8, schema_json: []const u8) !Validator {
        var query = try Query.open(allocator, path, .{});
        errdefer query.deinit();
        const schema = try allocator.create(Schema);
        errdefer allocator.destroy(schema);
        schema.* = try parseSchema(allocator, query.header(), schema_json);
        return .{ .allocator = allocator, .query = query, .schema = schema, .owned_schema = schema };
    }

    /// A report owns the entire pass; mixing it with streaming is refused.
    pub fn report(self: *Validator, options: ReportOptions) !Report {
        if (self.row_number != 0) return error.ValidatorAlreadyStarted;
        return reportFromValidator(self.allocator, self, options);
    }

    pub fn deinit(self: *Validator) void {
        self.errors.deinit(self.allocator);
        self.query.deinit();
        if (self.owned_schema) |schema| {
            schema.deinit();
            self.allocator.destroy(schema);
        }
    }

    pub fn header(self: *const Validator) [][]const u8 {
        return self.query.header();
    }

    pub fn next(self: *Validator) !?ValidatedRow {
        return self.nextWithSink(std.math.maxInt(usize), null);
    }

    fn nextWithSink(self: *Validator, limit: usize, counts: ?*[n_error_kinds]u64) !?ValidatedRow {
        const row = (try self.query.next()) orelse return null;
        self.row_number += 1;
        self.errors.clearRetainingCapacity();
        var sink = ErrorSink{ .allocator = self.allocator, .errors = &self.errors, .row_number = self.row_number, .counts = counts, .limit = limit };
        try self.check(row, &sink);
        if (sink.failed) self.rows_invalid += 1 else self.rows_valid += 1;
        return .{ .number = self.row_number, .row = row, .errors = self.errors.items };
    }

    fn check(self: *Validator, row: Row, sink: *ErrorSink) !void {
        // Structural first: it explains every rule failure that follows
        // on a torn row, so it should be the first thing a reader sees.
        if (row.fields.len < self.schema.n_columns) {
            try sink.add(null, "", .too_few_fields, "");
        } else if (row.fields.len > self.schema.n_columns) {
            try sink.add(null, "", .too_many_fields, "");
        }

        for (self.schema.rules) |*rule| {
            // A missing cell on a short row is already reported as
            // too_few_fields; repeating it per column would bury that.
            const value = row.get(rule.column) orelse continue;

            if (isBlank(value)) {
                // An empty optional cell is not a type error, a range
                // error or a length error — it is simply absent. Only
                // `required` has anything to say about it.
                if (rule.required) try sink.add(rule.column, rule.name, .missing_required, value);
                continue;
            }

            // Float type and range share one parse, including failure.
            var number: ?f64 = null;
            const type_ok = if (rule.type == .float) blk: {
                number = numeric(value);
                break :blk number != null;
            } else matchesType(rule.type, value);
            if (!type_ok) {
                try sink.add(rule.column, rule.name, .bad_type, value);
                continue; // range/length checks on a wrong-typed cell say nothing new
            }

            if (rule.min != null or rule.max != null) {
                if (rule.type != .float) number = numeric(value);
                if (number) |n| {
                    if (rule.min) |m| {
                        if (n < m) try sink.add(rule.column, rule.name, .below_min, value);
                    }
                    if (rule.max) |m| {
                        if (n > m) try sink.add(rule.column, rule.name, .above_max, value);
                    }
                } else {
                    // min/max were asked for, so this cell had to be a
                    // number and is not — regardless of what `type` said.
                    try sink.add(rule.column, rule.name, .bad_type, value);
                }
            }

            if (rule.min_len != null or rule.max_len != null) {
                const len = textLength(value);
                if (rule.min_len) |m| {
                    if (len < m) try sink.add(rule.column, rule.name, .too_short, value);
                }
                if (rule.max_len) |m| {
                    if (len > m) try sink.add(rule.column, rule.name, .too_long, value);
                }
            }

            if (rule.one_of.len > 0) {
                const found = if (rule.one_of_index) |index| index.contains(value) else blk: {
                    for (rule.one_of) |v| {
                        if (std.mem.eql(u8, v, value)) break :blk true;
                    }
                    break :blk false;
                };
                if (!found) try sink.add(rule.column, rule.name, .not_in_set, value);
            }
        }
    }
};

// ── the summary ──────────────────────────────────────────────────────

pub const ReportOptions = struct {
    /// How many individual errors to keep. Every error is still counted;
    /// this bounds only what is stored, so a wholly-broken file produces
    /// a report rather than an allocation failure.
    max_errors: usize = 100,
};

pub const Report = struct {
    allocator: Allocator,
    rows_total: u64 = 0,
    rows_valid: u64 = 0,
    rows_invalid: u64 = 0,
    /// Total failures seen, which can exceed `errors.len` — see
    /// `truncated`.
    errors_total: u64 = 0,
    /// Per-kind totals, indexed by @intFromEnum(ErrorKind). Complete
    /// even when the error list is capped, so a summary is never a lie.
    counts: [n_error_kinds]u64 = [_]u64{0} ** n_error_kinds,
    errors: []RowError = &.{},
    truncated: bool = false,
    /// Owns the copied `value` and `column_name` strings the errors
    /// point at, since the scan buffer they came from is long gone.
    strings: std.heap.ArenaAllocator,

    pub fn deinit(self: *Report) void {
        self.allocator.free(self.errors);
        self.strings.deinit();
    }
};

pub fn validate(
    allocator: Allocator,
    path: []const u8,
    schema: *const Schema,
    options: ReportOptions,
) !Report {
    var v = try Validator.open(allocator, path, schema);
    defer v.deinit();

    return v.report(options);
}

pub fn validateJson(allocator: Allocator, path: []const u8, schema_json: []const u8, options: ReportOptions) !Report {
    var v = try Validator.openJson(allocator, path, schema_json);
    defer v.deinit();
    return v.report(options);
}

fn reportFromValidator(allocator: Allocator, v: *Validator, options: ReportOptions) !Report {
    var report = Report{ .allocator = allocator, .strings = std.heap.ArenaAllocator.init(allocator) };
    errdefer report.deinit();
    const arena = report.strings.allocator();

    var kept: std.ArrayListUnmanaged(RowError) = .{};
    errdefer kept.deinit(allocator);

    while (try v.nextWithSink(options.max_errors - kept.items.len, &report.counts)) |vr| {
        for (vr.errors) |e| {
            try kept.append(allocator, .{
                .row = e.row,
                .column = e.column,
                .column_name = try arena.dupe(u8, e.column_name),
                .kind = e.kind,
                .value = try arena.dupe(u8, e.value),
            });
        }
    }
    for (report.counts) |count| report.errors_total += count;
    report.truncated = report.errors_total > kept.items.len;

    report.rows_total = v.row_number;
    report.rows_valid = v.rows_valid;
    report.rows_invalid = v.rows_invalid;
    report.errors = try kept.toOwnedSlice(allocator);
    return report;
}

// ── schema from JSON ─────────────────────────────────────────────────

/// Schemas cross the C ABI as JSON so that Python, Node and the CLI all
/// hand the same text to the same parser. Anything else means three
/// implementations of "what does min_len mean", which is exactly the
/// drift this module exists to prevent.
///
///     {
///       "id":     {"type": "integer", "required": true},
///       "amount": {"type": "float", "min": 0},
///       "status": {"one_of": ["new", "paid", "shipped"]},
///       "email":  {"required": true, "max_len": 255}
///     }
///
/// Every key must name a real column: a typo in a schema is a silently
/// unenforced rule, which is worse than a failed call.
pub fn parseSchema(
    allocator: Allocator,
    header: []const []const u8,
    json_text: []const u8,
) ValidateError!Schema {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch
        return ValidateError.BadSchema;
    defer parsed.deinit();
    if (parsed.value != .object) return ValidateError.BadSchema;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const astore = arena.allocator();

    var rules: std.ArrayListUnmanaged(Rule) = .{};
    errdefer rules.deinit(allocator);

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const col_name = entry.key_ptr.*;
        const idx = indexOfColumn(header, col_name) orelse return ValidateError.UnknownColumn;
        if (entry.value_ptr.* != .object) return ValidateError.BadSchema;
        const spec = entry.value_ptr.*.object;

        var rule = Rule{ .column = idx, .name = try astore.dupe(u8, col_name) };
        var field_it = spec.iterator();
        while (field_it.next()) |f| {
            const key = f.key_ptr.*;
            const val = f.value_ptr.*;
            if (std.mem.eql(u8, key, "type")) {
                if (val != .string) return ValidateError.BadSchema;
                rule.type = ColumnType.parse(val.string) orelse return ValidateError.BadSchema;
            } else if (std.mem.eql(u8, key, "required")) {
                if (val != .bool) return ValidateError.BadSchema;
                rule.required = val.bool;
            } else if (std.mem.eql(u8, key, "min")) {
                rule.min = try jsonNumber(val);
            } else if (std.mem.eql(u8, key, "max")) {
                rule.max = try jsonNumber(val);
            } else if (std.mem.eql(u8, key, "min_len")) {
                rule.min_len = try jsonCount(val);
            } else if (std.mem.eql(u8, key, "max_len")) {
                rule.max_len = try jsonCount(val);
            } else if (std.mem.eql(u8, key, "one_of")) {
                if (val != .array) return ValidateError.BadSchema;
                const items = try astore.alloc([]const u8, val.array.items.len);
                for (val.array.items, 0..) |v, i| {
                    items[i] = switch (v) {
                        .string => try astore.dupe(u8, v.string),
                        // A number in an enum list is text as far as a
                        // scanned field is concerned, so accept it and
                        // render it rather than rejecting the schema.
                        .integer => try std.fmt.allocPrint(astore, "{d}", .{v.integer}),
                        .float => try std.fmt.allocPrint(astore, "{d}", .{v.float}),
                        else => return ValidateError.BadSchema,
                    };
                }
                rule.one_of = items;
            } else {
                // An unrecognised key is a typo, and a typo'd rule is a
                // rule that silently does not run.
                return ValidateError.BadSchema;
            }
        }
        // Short enums are cheaper to scan; large enums get one lookup.
        if (rule.one_of.len >= 32) {
            var index: std.StringHashMapUnmanaged(void) = .{};
            for (rule.one_of) |value| try index.put(astore, value, {});
            rule.one_of_index = index;
        }
        try rules.append(allocator, rule);
    }

    return .{
        .allocator = allocator,
        .rules = try rules.toOwnedSlice(allocator),
        .n_columns = header.len,
        .strings = arena,
    };
}

fn jsonNumber(v: std.json.Value) ValidateError!f64 {
    return switch (v) {
        .integer => @floatFromInt(v.integer),
        .float => v.float,
        .number_string => std.fmt.parseFloat(f64, v.number_string) catch ValidateError.BadSchema,
        else => ValidateError.BadSchema,
    };
}

fn jsonCount(v: std.json.Value) ValidateError!usize {
    return switch (v) {
        .integer => if (v.integer < 0) ValidateError.BadSchema else @intCast(v.integer),
        else => ValidateError.BadSchema,
    };
}

fn indexOfColumn(header: []const []const u8, name: []const u8) ?usize {
    for (header, 0..) |h, i| {
        if (std.mem.eql(u8, h, name)) return i;
    }
    return null;
}

// ── JSON rendering ───────────────────────────────────────────────────
//
// Rendered here, once, rather than in each binding. The C ABI, the
// N-API addon and the CLI all emit this exact shape, so "what does a
// validation error look like" has a single answer no matter which
// client asked.

fn writeErrorObject(w: *std.io.Writer, e: RowError) !void {
    try w.print("{{\"row\":{d},\"column\":", .{e.row});
    if (e.column) |c| try w.print("{d}", .{c}) else try w.writeAll("null");
    try w.writeAll(",\"column_name\":");
    try std.json.Stringify.value(e.column_name, .{}, w);
    try w.writeAll(",\"rule\":");
    try std.json.Stringify.value(e.kind.name(), .{}, w);
    try w.writeAll(",\"value\":");
    try std.json.Stringify.value(e.value, .{}, w);
    try w.writeAll("}");
}

/// One row's failures, as a JSON array. Used by the streaming path,
/// which emits this only for rows that actually have errors.
pub fn writeRowErrorsJson(w: *std.io.Writer, errors: []const RowError) !void {
    try w.writeByte('[');
    for (errors, 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try writeErrorObject(w, e);
    }
    try w.writeByte(']');
}

/// The full report. `counts` is emitted only for kinds that actually
/// occurred, so a clean file's report does not carry nine zeroes.
pub fn writeReportJson(w: *std.io.Writer, r: Report) !void {
    try w.print(
        "{{\"rows_total\":{d},\"rows_valid\":{d},\"rows_invalid\":{d},\"errors_total\":{d},\"truncated\":{s},\"counts\":{{",
        .{ r.rows_total, r.rows_valid, r.rows_invalid, r.errors_total, if (r.truncated) "true" else "false" },
    );
    var first = true;
    for (r.counts, 0..) |n, i| {
        if (n == 0) continue;
        if (!first) try w.writeByte(',');
        first = false;
        const kind: ErrorKind = @enumFromInt(i);
        try std.json.Stringify.value(kind.name(), .{}, w);
        try w.print(":{d}", .{n});
    }
    try w.writeAll("},\"errors\":");
    try writeRowErrorsJson(w, r.errors);
    try w.writeByte('}');
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn withFile(comptime name: []const u8, data: []const u8) ![]const u8 {
    try std.fs.cwd().writeFile(.{ .sub_path = name, .data = data });
    return name;
}

/// Opens a file, parses `schema_json` against its real header, and runs
/// a full report — the shape every binding will use.
fn reportOf(allocator: Allocator, path: []const u8, schema_json: []const u8, opts: ReportOptions) !struct { report: Report, schema: Schema } {
    var probe = try Query.open(allocator, path, .{});
    const header = try allocator.alloc([]const u8, probe.header().len);
    defer {
        for (header) |h| allocator.free(@constCast(h));
        allocator.free(header);
    }
    for (probe.header(), 0..) |h, i| header[i] = try allocator.dupe(u8, h);
    probe.deinit();

    var schema = try parseSchema(allocator, header, schema_json);
    errdefer schema.deinit();
    const report = try validate(allocator, path, &schema, opts);
    return .{ .report = report, .schema = schema };
}

test "a clean file reports no errors at all" {
    const a = testing.allocator;
    const path = try withFile("test_val_clean.csv", "id,name,amount\n1,Alice,10\n2,Bob,20\n");
    defer std.fs.cwd().deleteFile(path) catch {};

    var r = try reportOf(a, path,
        \\{"id": {"type": "integer", "required": true}, "amount": {"type": "float", "min": 0}}
    , .{});
    defer r.report.deinit();
    defer r.schema.deinit();

    try testing.expectEqual(@as(u64, 2), r.report.rows_total);
    try testing.expectEqual(@as(u64, 2), r.report.rows_valid);
    try testing.expectEqual(@as(u64, 0), r.report.rows_invalid);
    try testing.expectEqual(@as(u64, 0), r.report.errors_total);
    try testing.expect(!r.report.truncated);
}

test "each rule reports its own kind, against the offending cell" {
    const a = testing.allocator;
    const path = try withFile("test_val_kinds.csv", "id,amount,status,code\n" ++
        "abc,5,new,XY\n" ++ // id not an integer
        "2,-1,new,XY\n" ++ // amount below min
        "3,5,bogus,XY\n" ++ // status not in set
        "4,5,new,TOOLONG\n" ++ // code too long
        "5,5,new,\n" // code required, blank
    );
    defer std.fs.cwd().deleteFile(path) catch {};

    var r = try reportOf(a, path,
        \\{"id": {"type": "integer"},
        \\ "amount": {"type": "float", "min": 0},
        \\ "status": {"one_of": ["new", "paid"]},
        \\ "code": {"required": true, "max_len": 4}}
    , .{});
    defer r.report.deinit();
    defer r.schema.deinit();

    try testing.expectEqual(@as(u64, 5), r.report.rows_total);
    try testing.expectEqual(@as(u64, 0), r.report.rows_valid);
    try testing.expectEqual(@as(u64, 5), r.report.rows_invalid);
    try testing.expectEqual(@as(usize, 5), r.report.errors.len);

    const e = r.report.errors;
    try testing.expectEqual(ErrorKind.bad_type, e[0].kind);
    try testing.expectEqualStrings("abc", e[0].value);
    try testing.expectEqualStrings("id", e[0].column_name);
    try testing.expectEqual(@as(u64, 1), e[0].row);
    try testing.expectEqual(ErrorKind.below_min, e[1].kind);
    try testing.expectEqual(ErrorKind.not_in_set, e[2].kind);
    try testing.expectEqual(ErrorKind.too_long, e[3].kind);
    try testing.expectEqual(ErrorKind.missing_required, e[4].kind);
}

test "an empty optional cell is absent, not badly typed" {
    // The rule that keeps a report readable: a sparse column would
    // otherwise raise one bad_type per blank cell and drown the real
    // failures.
    const a = testing.allocator;
    const path = try withFile("test_val_blank.csv", "id,note\n1,\n2,   \n3,hello\n");
    defer std.fs.cwd().deleteFile(path) catch {};

    var r = try reportOf(a, path,
        \\{"note": {"type": "integer", "min_len": 3}}
    , .{});
    defer r.report.deinit();
    defer r.schema.deinit();
    try testing.expectEqual(@as(u64, 1), r.report.errors_total); // only "hello"
    try testing.expectEqual(ErrorKind.bad_type, r.report.errors[0].kind);
    try testing.expectEqual(@as(u64, 3), r.report.errors[0].row);
}

test "required sees whitespace as blank, because a cleared cell is empty" {
    const a = testing.allocator;
    const path = try withFile("test_val_ws.csv", "id,name\n1,   \n2,Bob\n");
    defer std.fs.cwd().deleteFile(path) catch {};

    var r = try reportOf(a, path,
        \\{"name": {"required": true}}
    , .{});
    defer r.report.deinit();
    defer r.schema.deinit();
    try testing.expectEqual(@as(u64, 1), r.report.errors_total);
    try testing.expectEqual(ErrorKind.missing_required, r.report.errors[0].kind);
}

test "structural errors are reported per row, not per missing column" {
    const a = testing.allocator;
    const path = try withFile("test_val_ragged.csv", "a,b,c\n1,2,3\n4,5\n6,7,8,9\n");
    defer std.fs.cwd().deleteFile(path) catch {};

    var r = try reportOf(a, path,
        \\{"a": {"required": true}, "b": {"required": true}, "c": {"required": true}}
    , .{});
    defer r.report.deinit();
    defer r.schema.deinit();

    try testing.expectEqual(@as(u64, 3), r.report.rows_total);
    try testing.expectEqual(@as(u64, 1), r.report.rows_valid);
    // One error per bad row — a two-field row does NOT also raise
    // missing_required for the column it never had.
    try testing.expectEqual(@as(u64, 2), r.report.errors_total);
    try testing.expectEqual(ErrorKind.too_few_fields, r.report.errors[0].kind);
    try testing.expectEqual(@as(?usize, null), r.report.errors[0].column);
    try testing.expectEqual(ErrorKind.too_many_fields, r.report.errors[1].kind);
    try testing.expectEqual(@as(u64, 1), r.report.counts[@intFromEnum(ErrorKind.too_few_fields)]);
    try testing.expectEqual(@as(u64, 1), r.report.counts[@intFromEnum(ErrorKind.too_many_fields)]);
}

test "a wholly-broken file produces a capped report, not an allocation the size of the file" {
    const a = testing.allocator;
    var data: std.ArrayListUnmanaged(u8) = .{};
    defer data.deinit(a);
    try data.appendSlice(a, "id\n");
    for (0..5000) |_| try data.appendSlice(a, "nope\n");
    const path = try withFile("test_val_capped.csv", data.items);
    defer std.fs.cwd().deleteFile(path) catch {};

    var r = try reportOf(a, path,
        \\{"id": {"type": "integer"}}
    , .{ .max_errors = 10 });
    defer r.report.deinit();
    defer r.schema.deinit();

    try testing.expectEqual(@as(usize, 10), r.report.errors.len);
    // Counts stay complete even though the list is capped — a summary
    // that under-reports would be worse than no summary.
    try testing.expectEqual(@as(u64, 5000), r.report.errors_total);
    try testing.expectEqual(@as(u64, 5000), r.report.counts[@intFromEnum(ErrorKind.bad_type)]);
    try testing.expectEqual(@as(u64, 5000), r.report.rows_invalid);
    try testing.expect(r.report.truncated);
}

test "Validator streams rows with their errors attached and holds nothing else" {
    const a = testing.allocator;
    const path = try withFile("test_val_stream.csv", "id,amount\n1,10\n2,oops\n3,30\n");
    defer std.fs.cwd().deleteFile(path) catch {};

    var probe = try Query.open(a, path, .{});
    const header = try a.alloc([]const u8, probe.header().len);
    defer {
        for (header) |h| a.free(@constCast(h));
        a.free(header);
    }
    for (probe.header(), 0..) |h, i| header[i] = try a.dupe(u8, h);
    probe.deinit();

    var schema = try parseSchema(a, header,
        \\{"amount": {"type": "float"}}
    );
    defer schema.deinit();

    var v = try Validator.open(a, path, &schema);
    defer v.deinit();

    var good: usize = 0;
    var bad: usize = 0;
    while (try v.next()) |vr| {
        if (vr.isValid()) {
            good += 1;
        } else {
            bad += 1;
            try testing.expectEqual(@as(u64, 2), vr.number);
            try testing.expectEqualStrings("oops", vr.errors[0].value);
            // The row itself is still there — an importer needs it to
            // write a rejects file, not just the error.
            try testing.expectEqualStrings("2", vr.row.get(0).?);
        }
    }
    try testing.expectEqual(@as(usize, 2), good);
    try testing.expectEqual(@as(usize, 1), bad);
}

test "NDJSON validates through the same rules as CSV" {
    const a = testing.allocator;
    const path = try withFile("test_val.ndjson",
        \\{"id": 1, "amount": 10}
        \\{"id": 2, "amount": "oops"}
        \\
    );
    defer std.fs.cwd().deleteFile(path) catch {};

    var r = try reportOf(a, path,
        \\{"amount": {"type": "float"}}
    , .{});
    defer r.report.deinit();
    defer r.schema.deinit();
    try testing.expectEqual(@as(u64, 2), r.report.rows_total);
    try testing.expectEqual(@as(u64, 1), r.report.rows_invalid);
    try testing.expectEqual(ErrorKind.bad_type, r.report.errors[0].kind);
}

test "type checks: integer, float, boolean, datetime" {
    try testing.expect(isInteger("42"));
    try testing.expect(isInteger("-42"));
    try testing.expect(isInteger("+42"));
    try testing.expect(!isInteger("4.2"));
    try testing.expect(!isInteger("1e3")); // an integer column means digits
    try testing.expect(!isInteger(""));
    try testing.expect(!isInteger("-"));

    try testing.expect(matchesType(.float, "1e3"));
    try testing.expect(matchesType(.float, "-0.5"));
    // "nan"/"inf" are text, per the library's one definition of a number.
    try testing.expect(!matchesType(.float, "nan"));
    try testing.expect(!matchesType(.float, "inf"));

    try testing.expect(isBoolean("TRUE"));
    try testing.expect(isBoolean("false"));
    try testing.expect(!isBoolean("1"));

    try testing.expect(isDatetime("2024-01-31"));
    try testing.expect(isDatetime("2024-01-31T12:30:00Z"));
    try testing.expect(isDatetime("2024-01-31 12:30"));
    try testing.expect(isDatetime("2024-01-31T12:30:00.123+02:00"));
    try testing.expect(!isDatetime("2024-13-01")); // month 13
    try testing.expect(!isDatetime("2024-01-32")); // day 32
    try testing.expect(!isDatetime("31/01/2024"));
    try testing.expect(!isDatetime("2024-01-31T99:00"));
    try testing.expect(!isDatetime("2024-01-31Tnonsense"));
}

test "max_len counts characters, not bytes" {
    const a = testing.allocator;
    const path = try withFile("test_val_utf8.csv", "city\nZürich\nLos Angeles\n");
    defer std.fs.cwd().deleteFile(path) catch {};

    var r = try reportOf(a, path,
        \\{"city": {"max_len": 6}}
    , .{});
    defer r.report.deinit();
    defer r.schema.deinit();
    // "Zürich" is 7 bytes but 6 characters, and must pass.
    try testing.expectEqual(@as(u64, 1), r.report.errors_total);
    try testing.expectEqualStrings("Los Angeles", r.report.errors[0].value);
}

test "a schema naming a column the file does not have is an error, not a silent no-op" {
    const a = testing.allocator;
    const header = [_][]const u8{ "id", "name" };
    try testing.expectError(ValidateError.UnknownColumn, parseSchema(a, &header,
        \\{"nope": {"required": true}}
    ));
    // Same for a misspelled rule: a rule that does not run is worse than
    // a call that fails.
    try testing.expectError(ValidateError.BadSchema, parseSchema(a, &header,
        \\{"id": {"requred": true}}
    ));
    try testing.expectError(ValidateError.BadSchema, parseSchema(a, &header,
        \\{"id": {"type": "intger"}}
    ));
    try testing.expectError(ValidateError.BadSchema, parseSchema(a, &header, "not json"));
    try testing.expectError(ValidateError.BadSchema, parseSchema(a, &header, "[]"));
}

test "one_of accepts numbers written as numbers in the schema" {
    const a = testing.allocator;
    const path = try withFile("test_val_oneof.csv", "code\n1\n2\n9\n");
    defer std.fs.cwd().deleteFile(path) catch {};

    var r = try reportOf(a, path,
        \\{"code": {"one_of": [1, 2]}}
    , .{});
    defer r.report.deinit();
    defer r.schema.deinit();
    try testing.expectEqual(@as(u64, 1), r.report.errors_total);
    try testing.expectEqualStrings("9", r.report.errors[0].value);
}

test "min and max both fire, and a non-numeric cell under them is a type error" {
    const a = testing.allocator;
    const path = try withFile("test_val_range.csv", "n\n5\n50\n500\nxyz\n");
    defer std.fs.cwd().deleteFile(path) catch {};

    var r = try reportOf(a, path,
        \\{"n": {"min": 10, "max": 100}}
    , .{});
    defer r.report.deinit();
    defer r.schema.deinit();
    try testing.expectEqual(@as(u64, 3), r.report.errors_total);
    try testing.expectEqual(ErrorKind.below_min, r.report.errors[0].kind);
    try testing.expectEqual(ErrorKind.above_max, r.report.errors[1].kind);
    try testing.expectEqual(ErrorKind.bad_type, r.report.errors[2].kind);
}

test "quoted CSV validates on the unquoted value" {
    // The splitter runs first, so a rule sees "Smith, John", not
    // "\"Smith" — the two would give opposite answers on max_len.
    const a = testing.allocator;
    const path = try withFile("test_val_quoted.csv", "id,name\n1,\"Smith, John\"\n2,\"\"\n");
    defer std.fs.cwd().deleteFile(path) catch {};

    var r = try reportOf(a, path,
        \\{"name": {"required": true, "max_len": 11}}
    , .{});
    defer r.report.deinit();
    defer r.schema.deinit();
    // Row 1: "Smith, John" is exactly 11 chars, and is one field.
    // Row 2: an empty quoted field is blank, so required fires.
    try testing.expectEqual(@as(u64, 1), r.report.errors_total);
    try testing.expectEqual(ErrorKind.missing_required, r.report.errors[0].kind);
    try testing.expectEqual(@as(u64, 2), r.report.errors[0].row);
}

test "the JSON report is the shape every binding promises" {
    const a = testing.allocator;
    const path = try withFile("test_val_json.csv", "id,amount\n1,10\nx,20\n");
    defer std.fs.cwd().deleteFile(path) catch {};

    var r = try reportOf(a, path,
        \\{"id": {"type": "integer"}}
    , .{});
    defer r.report.deinit();
    defer r.schema.deinit();

    var w: std.io.Writer.Allocating = .init(a);
    defer w.deinit();
    try writeReportJson(&w.writer, r.report);
    try testing.expectEqualStrings(
        "{\"rows_total\":2,\"rows_valid\":1,\"rows_invalid\":1,\"errors_total\":1," ++
            "\"truncated\":false,\"counts\":{\"bad_type\":1}," ++
            "\"errors\":[{\"row\":2,\"column\":0,\"column_name\":\"id\",\"rule\":\"bad_type\",\"value\":\"x\"}]}",
        w.written(),
    );
}

test "a structural error renders its column as null, not as a fake index" {
    const a = testing.allocator;
    const path = try withFile("test_val_json2.csv", "a,b\n1\n");
    defer std.fs.cwd().deleteFile(path) catch {};

    var r = try reportOf(a, path, "{}", .{});
    defer r.report.deinit();
    defer r.schema.deinit();

    var w: std.io.Writer.Allocating = .init(a);
    defer w.deinit();
    try writeRowErrorsJson(&w.writer, r.report.errors);
    try testing.expectEqualStrings(
        "[{\"row\":1,\"column\":null,\"column_name\":\"\",\"rule\":\"too_few_fields\",\"value\":\"\"}]",
        w.written(),
    );
}

test "surrounding whitespace is not data, for every numeric rule alike" {
    // ` 55 ` used to pass `integer` (which trims) and fail `float` and
    // `min` (which did not) — the same cell valid under one rule and
    // malformed under another.
    const a = testing.allocator;
    const path = try withFile("test_val_pad.csv", "n\n 55 \n\t7\t\n 4 \n");
    defer std.fs.cwd().deleteFile(path) catch {};

    for ([_][]const u8{
        \\{"n": {"type": "integer"}}
        ,
        \\{"n": {"type": "float"}}
        ,
    }) |schema_json| {
        var r = try reportOf(a, path, schema_json, .{});
        defer r.report.deinit();
        defer r.schema.deinit();
        try testing.expectEqual(@as(u64, 0), r.report.errors_total);
    }

    var r = try reportOf(a, path,
        \\{"n": {"min": 5}}
    , .{});
    defer r.report.deinit();
    defer r.schema.deinit();
    // Only the genuine 4 is below the minimum — and the value is
    // reported exactly as it sits in the file, not trimmed.
    try testing.expectEqual(@as(u64, 1), r.report.errors_total);
    try testing.expectEqual(ErrorKind.below_min, r.report.errors[0].kind);
    try testing.expectEqualStrings(" 4 ", r.report.errors[0].value);
}

test "datetime checks Gregorian dates and timezone bounds" {
    for ([_][]const u8{ "2000-02-29", "2024-02-29T23:59:59Z", "2024-04-30", "2024-01-01T00:00+23:59", " 2024-01-01T00:00-00:00 " }) |value| {
        try testing.expect(isDatetime(value));
    }
    for ([_][]const u8{ "0000-01-01", "1900-02-29", "2023-02-29", "2024-02-30", "2024-04-31", "2024-01-01T00:00+24:00", "2024-01-01T00:00+00:60", "2024-01-01T00:00+99:99" }) |value| {
        try testing.expect(!isDatetime(value));
    }
}

test "capped report counts every failure and keeps the exact prefix" {
    const path = try withFile("test_val_sink.csv", "a,b\n1,\n2,\n3,ok\n");
    defer std.fs.cwd().deleteFile(path) catch {};
    var schema = try parseSchema(testing.allocator, &.{ "a", "b" }, "{\"a\":{\"min\":5,\"min_len\":2},\"b\":{\"required\":true}}");
    defer schema.deinit();
    var full = try validate(testing.allocator, path, &schema, .{ .max_errors = 100 });
    defer full.deinit();
    try testing.expectEqual(@as(u64, 8), full.errors_total);
    for ([_]usize{ 0, 1, 2, 3, 7, 8, 9 }) |cap| {
        var limited = try validate(testing.allocator, path, &schema, .{ .max_errors = cap });
        defer limited.deinit();
        try testing.expectEqual(full.rows_invalid, limited.rows_invalid);
        try testing.expectEqual(full.rows_valid, limited.rows_valid);
        try testing.expectEqual(full.errors_total, limited.errors_total);
        try testing.expectEqualSlices(u64, &full.counts, &limited.counts);
        try testing.expectEqual(@min(cap, full.errors.len), limited.errors.len);
        try testing.expectEqual(cap < full.errors.len, limited.truncated);
        for (limited.errors, full.errors[0..limited.errors.len]) |got, want| {
            try testing.expectEqual(want.row, got.row);
            try testing.expectEqual(want.kind, got.kind);
            try testing.expectEqualStrings(want.value, got.value);
        }
    }
    var v = try Validator.open(testing.allocator, path, &schema);
    defer v.deinit();
    var counts = [_]u64{0} ** n_error_kinds;
    _ = try v.nextWithSink(0, &counts);
    try testing.expectEqual(@as(usize, 0), v.errors.capacity);
    // Public streaming next always keeps its complete errors.
    const row = (try v.next()).?;
    try testing.expectEqual(@as(usize, 3), row.errors.len);
    try testing.expect(!row.isValid());
}

const large_enum_json = "{\"v\":{\"one_of\":[\"0\",\"1\",\"2\",\"3\",\"4\",\"5\",\"6\",\"7\",\"8\",\"9\",\"10\",\"11\",\"12\",\"13\",\"14\",\"15\",\"16\",\"17\",\"18\",\"19\",\"20\",\"21\",\"22\",\"23\",\"24\",\"25\",\"26\",\"27\",\"28\",\"29\",\"Zürich\",\"Zürich\"]}}";

fn enumAllocationCase(allocator: Allocator) !void {
    var schema = parseSchema(allocator, &.{"v"}, large_enum_json) catch |err| {
        // Valid constant JSON: parseFromSlice's BadSchema here can only
        // be its existing translation of an injected allocation failure.
        if (err == error.BadSchema) return error.OutOfMemory;
        return err;
    };
    defer schema.deinit();
    try testing.expect(schema.rules[0].one_of_index.?.contains("Zürich"));
    try testing.expect(!schema.rules[0].one_of_index.?.contains("absent"));
}

test "compiled enums clean up on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, enumAllocationCase, .{});
}

test "compiled enum agrees with linear membership including duplicates" {
    const path = try withFile("test_val_enum_index.csv", "v\n0\nZürich\nabsent\n29\n");
    defer std.fs.cwd().deleteFile(path) catch {};
    var schema = try parseSchema(testing.allocator, &.{"v"}, large_enum_json);
    defer schema.deinit();
    var indexed = try validate(testing.allocator, path, &schema, .{});
    defer indexed.deinit();
    // Exercise the fallback used by schemas assembled directly in Zig.
    schema.rules[0].one_of_index = null;
    var linear = try validate(testing.allocator, path, &schema, .{});
    defer linear.deinit();
    try testing.expectEqual(@as(u64, 1), indexed.rows_invalid);
    try testing.expectEqual(indexed.rows_invalid, linear.rows_invalid);
    try testing.expectEqualSlices(u64, &indexed.counts, &linear.counts);
    try testing.expectEqualStrings("absent", indexed.errors[0].value);
}

fn openJsonAllocationCase(allocator: Allocator, path: []const u8) !void {
    var validator = Validator.openJson(allocator, path, "{\"a\":{\"type\":\"integer\"}}") catch |e| {
        if (e == error.BadSchema) return error.OutOfMemory;
        return e;
    };
    defer validator.deinit();
    _ = try validator.next();
}

test "single-open validator owns schema through allocation failures" {
    const path = try withFile("test_val_single_open.csv", "a\n1\n2\n");
    defer std.fs.cwd().deleteFile(path) catch {};
    try testing.checkAllAllocationFailures(testing.allocator, openJsonAllocationCase, .{path});
    var validator = try Validator.openJson(testing.allocator, path, "{}");
    defer validator.deinit();
    const first = (try validator.next()).?;
    try testing.expectEqualStrings("1", first.row.get(0).?);
    try testing.expectError(error.ValidatorAlreadyStarted, validator.report(.{}));
    const second = (try validator.next()).?;
    try testing.expectEqualStrings("2", second.row.get(0).?);
}
