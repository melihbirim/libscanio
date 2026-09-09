//! `scanio` — the command-line front door to the same Query the Python,
//! Node and C ABI bindings use.
//!
//! This exists because of a measured gap, not for completeness. The
//! whole library's advantage on small-to-medium files is that it does
//! almost nothing before it starts scanning — a 1MB filtered scan takes
//! ~2ms of actual work. Reaching it through Python costs ~15ms of
//! interpreter and module startup before a single byte is read, and
//! through pyarrow's Table constructor ~130ms. Neither is this library's
//! cost, but both are paid by a caller who just wants one query answered
//! and the process gone. A binary skips all of it: no interpreter, no
//! dynamic-language import graph, no FFI marshalling.
//!
//! Streaming by design, like `Query` itself — rows are written out as
//! they are found and never collected, so peak memory tracks the read
//! buffer rather than the result size. `--count` runs through the
//! multi-threaded engine (parallelCountRowsWhere()) and never splits a
//! field with no WHERE clause — same as Python's/Node's count().
const std = @import("std");
const scanio = @import("scanio");
const where_parser = @import("where_parser.zig");
const csv = scanio.csv_fields;

const usage =
    \\usage: scanio <file> [options]
    \\
    \\  --where <clause>    "col OP val [AND col OP val ...]" or "col IN (a, b)"
    \\                      OP is one of = != > >= < <=
    \\  --columns <a,b,c>   only these columns, in this order
    \\  --limit <n>         stop after n matching rows
    \\  --count             print just the number of matching rows
    \\  --not               invert --where: emit the rows it REJECTS
    \\  --format <fmt>      csv (default) or ndjson
    \\  --help
    \\
    \\Import validation:
    \\  --validate <file>   JSON schema, keyed by column name:
    \\                        {"id": {"type": "integer", "required": true},
    \\                         "amount": {"type": "float", "min": 0}}
    \\                      Prints a JSON report; exits 1 if any row failed.
    \\  --valid             ...and instead stream only the rows that passed
    \\  --invalid           ...or only the rows that failed
    \\  --max-errors <n>    how many failures the report LISTS (default 100).
    \\                      Counts are always complete; 0 means no limit.
    \\
    \\Report mode is a gate: it exits 1 if any row failed, so it drops
    \\straight into a script. The two row modes are filters and exit 0
    \\whenever they ran, so a pipeline under `set -e` is not aborted by
    \\the very rejects it asked to see. --validate does not combine with
    \\--where/--columns/--limit/--count.
    \\
    \\Reads CSV, NDJSON and JSON arrays; the format is inferred from the
    \\file extension. Output streams as it is found, so memory stays flat
    \\regardless of how much matches.
    \\
;

pub const Format = enum { csv, ndjson };

/// Everything the CLI accepts, parsed but not yet resolved against a
/// file's header — kept separate from main() so it is testable without
/// a filesystem or a process.
pub const Args = struct {
    path: []const u8 = "",
    where: ?[]const u8 = null,
    columns: ?[]const u8 = null,
    limit: ?usize = null,
    count_only: bool = false,
    /// Invert the whole --where clause: emit its complement. Not a
    /// per-clause NOT — the case this exists for is "show me the rows
    /// that failed", which is the negation of the entire AND-list.
    negate: bool = false,
    format: Format = .csv,
    help: bool = false,
    /// Path to a JSON schema file. Set = run validation instead of a scan.
    validate: ?[]const u8 = null,
    /// How many individual failures the report lists. Null = the
    /// library default (100); 0 = list every one of them.
    max_errors: ?usize = null,
    /// What to emit under --validate. Report is the default; the two row
    /// modes are what makes this usable in a pipeline —
    /// `scanio in.csv --validate s.json --valid > clean.csv`.
    validate_output: ValidateOutput = .report,
};

pub const ValidateOutput = enum { report, valid, invalid };

pub const ArgError = error{
    MissingValue,
    UnknownFlag,
    UnknownFormat,
    BadLimit,
    MissingPath,
    ValidateRequired,
    ValidateConflict,
};

pub fn parseArgs(argv: []const []const u8) ArgError!Args {
    var a = Args{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            a.help = true;
            return a;
        } else if (std.mem.eql(u8, arg, "--count")) {
            a.count_only = true;
        } else if (std.mem.eql(u8, arg, "--not")) {
            a.negate = true;
        } else if (std.mem.eql(u8, arg, "--where")) {
            i += 1;
            if (i >= argv.len) return ArgError.MissingValue;
            a.where = argv[i];
        } else if (std.mem.eql(u8, arg, "--columns")) {
            i += 1;
            if (i >= argv.len) return ArgError.MissingValue;
            a.columns = argv[i];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i >= argv.len) return ArgError.MissingValue;
            a.limit = std.fmt.parseInt(usize, argv[i], 10) catch return ArgError.BadLimit;
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= argv.len) return ArgError.MissingValue;
            if (std.mem.eql(u8, argv[i], "csv")) {
                a.format = .csv;
            } else if (std.mem.eql(u8, argv[i], "ndjson")) {
                a.format = .ndjson;
            } else return ArgError.UnknownFormat;
        } else if (std.mem.eql(u8, arg, "--validate")) {
            i += 1;
            if (i >= argv.len) return ArgError.MissingValue;
            a.validate = argv[i];
        } else if (std.mem.eql(u8, arg, "--max-errors")) {
            i += 1;
            if (i >= argv.len) return ArgError.MissingValue;
            a.max_errors = std.fmt.parseInt(usize, argv[i], 10) catch return ArgError.BadLimit;
        } else if (std.mem.eql(u8, arg, "--valid")) {
            a.validate_output = .valid;
        } else if (std.mem.eql(u8, arg, "--invalid")) {
            a.validate_output = .invalid;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            return ArgError.UnknownFlag;
        } else if (a.path.len == 0) {
            a.path = arg;
        } else return ArgError.UnknownFlag;
    }
    if (a.path.len == 0) return ArgError.MissingPath;
    // --valid/--invalid select what a validation run emits; on their own
    // they would silently do nothing.
    if (a.validate == null and (a.validate_output != .report or a.max_errors != null)) {
        return ArgError.ValidateRequired;
    }
    // Silently ignoring a flag is worse than refusing it: a caller who
    // wrote `--validate s.json --where x = 1` believes the filter ran.
    if (a.validate != null and (a.where != null or a.columns != null or a.limit != null or a.count_only or a.negate)) {
        return ArgError.ValidateConflict;
    }
    return a;
}

/// Resolves a "a,b,c" column list against a header. Returns null for no
/// projection, which Query reads as "every column".
fn resolveColumns(allocator: std.mem.Allocator, header: []const []const u8, spec: ?[]const u8) !?[]usize {
    const s = spec orelse return null;
    var n: usize = 1;
    for (s) |c| {
        if (c == ',') n += 1;
    }
    const out = try allocator.alloc(usize, n);
    errdefer allocator.free(out);
    var it = std.mem.splitScalar(u8, s, ',');
    var i: usize = 0;
    while (it.next()) |raw| : (i += 1) {
        out[i] = try where_parser.resolveColumn(header, std.mem.trim(u8, raw, " \t"));
    }
    return out;
}

fn writeRow(out: *std.io.Writer, row: scanio.Row, names: []const []const u8, format: Format) !void {
    switch (format) {
        .csv => {
            for (row.fields, 0..) |f, i| {
                if (i > 0) try out.writeByte(',');
                // Re-quote: the scanner strips RFC 4180 quoting, so a
                // bare write would emit a field containing a comma as
                // two fields.
                try csv.writeField(out, f, ',');
            }
        },
        .ndjson => {
            try out.writeByte('{');
            for (row.fields, 0..) |f, i| {
                if (i > 0) try out.writeByte(',');
                // Keys can run past `names` if a row has more fields
                // than the header did — emit a positional key rather
                // than dropping the value or indexing out of bounds.
                if (i < names.len) {
                    try std.json.Stringify.value(names[i], .{}, out);
                } else {
                    try out.print("\"col{d}\"", .{i});
                }
                try out.writeByte(':');
                try std.json.Stringify.value(f, .{}, out);
            }
            try out.writeByte('}');
        },
    }
    try out.writeByte('\n');
}

pub fn main() !u8 {
    // c_allocator, matching every other binding — see ndjson.zig's doc
    // comment for the measured reason this is not a GeneralPurposeAllocator.
    const allocator = std.heap.c_allocator;

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_w = std.fs.File.stderr().writer(&stderr_buf);
    const err_out = &stderr_w.interface;

    const args = parseArgs(@ptrCast(argv[1..])) catch |e| {
        try err_out.print("scanio: {s}\n\n{s}", .{ @errorName(e), usage });
        try err_out.flush();
        return 2;
    };
    if (args.help) {
        try err_out.writeAll(usage);
        try err_out.flush();
        return 0;
    }

    if (args.validate) |schema_path| {
        var buffer: [64 * 1024]u8 = undefined;
        var writer = std.fs.File.stdout().writer(&buffer);
        return runValidate(allocator, args, schema_path, &writer.interface, err_out);
    }

    // Probe the header first so --where/--columns can be resolved by
    // name, the same two-open pattern every other binding uses.
    var probe = scanio.Query.open(allocator, args.path, .{}) catch |e| {
        try err_out.print("scanio: cannot open {s}: {s}\n", .{ args.path, @errorName(e) });
        try err_out.flush();
        return 1;
    };
    const header = probe.header();
    var owned_header = try allocator.alloc([]const u8, header.len);
    defer {
        for (owned_header) |h| allocator.free(@constCast(h));
        allocator.free(owned_header);
    }
    for (header, 0..) |h, i| owned_header[i] = try allocator.dupe(u8, h);
    probe.deinit();

    const predicates = if (args.where) |w|
        where_parser.parseWhereString(allocator, owned_header, w) catch |e| {
            try err_out.print("scanio: bad --where: {s}\n", .{@errorName(e)});
            try err_out.flush();
            return 2;
        }
    else
        &[_]scanio.Predicate{};
    defer if (predicates.len > 0) where_parser.freePredicates(allocator, @constCast(predicates));

    // The multi-threaded engine, same as Python's/Node's count() — never
    // opens the single-threaded Query at all for this path (matches
    // those two bindings exactly, not just in spirit: parallelCountRowsWhere()
    // already handles empty predicates, negate, and stop_after_column
    // internally, and now skips spawning a thread at all below
    // threadsFor()'s size threshold — fixed after a real Windows-only
    // crash traced to spawning one unconditionally, even for a 3-row
    // file — see ROADMAP.md). --columns/--limit are accepted by the
    // shared arg parser but never applied to a count in any binding,
    // this one included: Python's/Node's count() takes no limit or
    // columns parameter at all. Real, measured win — see ROADMAP.md.
    if (args.count_only) {
        var stdout_buf: [64 * 1024]u8 = undefined;
        var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
        const out = &stdout_w.interface;
        const n = scanio.parallelCountRowsWhere(allocator, args.path, ',', predicates, args.negate, 0) catch |e| {
            try err_out.print("scanio: scan failed: {s}\n", .{@errorName(e)});
            try err_out.flush();
            return 1;
        };
        try out.print("{d}\n", .{n});
        try out.flush();
        return 0;
    }

    const columns = resolveColumns(allocator, owned_header, args.columns) catch |e| {
        try err_out.print("scanio: bad --columns: {s}\n", .{@errorName(e)});
        try err_out.flush();
        return 2;
    };
    defer if (columns) |c| allocator.free(c);

    // Highest column anything will read — lets both the CSV splitter and
    // the NDJSON key walk stop early (see QueryOptions.stop_after_column).
    var max_col: ?usize = where_parser.maxPredicateColumn(predicates, null);
    if (columns) |cols| {
        for (cols) |c| {
            if (max_col == null or c > max_col.?) max_col = c;
        }
    } else {
        max_col = null; // no projection: every column is read
    }

    var q = scanio.Query.open(allocator, args.path, .{
        .where = predicates,
        .negate = args.negate,
        .columns = columns,
        .limit = args.limit,
        .stop_after_column = max_col,
    }) catch |e| {
        try err_out.print("scanio: cannot open {s}: {s}\n", .{ args.path, @errorName(e) });
        try err_out.flush();
        return 1;
    };
    defer q.deinit();

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    const out = &stdout_w.interface;

    // Projected output needs the projected names, in the projected order.
    var out_names = owned_header;
    var projected_names: ?[][]const u8 = null;
    defer if (projected_names) |p| allocator.free(p);
    if (columns) |cols| {
        const p = try allocator.alloc([]const u8, cols.len);
        for (cols, 0..) |c, i| p[i] = if (c < owned_header.len) owned_header[c] else "";
        projected_names = p;
        out_names = p;
    }

    while (q.next() catch |e| {
        try err_out.print("scanio: scan failed: {s}\n", .{@errorName(e)});
        try err_out.flush();
        return 1;
    }) |row| {
        try writeRow(out, row, out_names, args.format);
    }
    try out.flush();
    return 0;
}

/// Validation is its own run, not a filter layered on the scan above:
/// it reads the file through Validator, which reports per-cell reasons a
/// WHERE clause has no way to express.
///
/// Exit code 1 when any row failed, so `scanio in.csv --validate s.json`
/// works as a pre-flight gate in a shell script without parsing the
/// report.
fn runValidate(
    allocator: std.mem.Allocator,
    args: Args,
    schema_path: []const u8,
    out: *std.io.Writer,
    err_out: *std.io.Writer,
) !u8 {
    const schema_json = std.fs.cwd().readFileAlloc(allocator, schema_path, 4 * 1024 * 1024) catch |e| {
        try err_out.print("scanio: cannot read schema {s}: {s}\n", .{ schema_path, @errorName(e) });
        try err_out.flush();
        return 2;
    };
    defer allocator.free(schema_json);

    var v = scanio.Validator.openJson(allocator, args.path, schema_json) catch |e| {
        try err_out.print("scanio: cannot validate {s}: {s}\n", .{ args.path, @errorName(e) });
        try err_out.flush();
        return switch (e) {
            error.BadSchema, error.UnknownColumn => 2,
            else => 1,
        };
    };
    defer v.deinit();
    const header = v.header();

    if (args.validate_output == .report) {
        var report = v.report(.{
            // 0 means "list them all", which the library spells as a
            // cap nothing can reach — its own 0 means "use the default".
            .max_errors = if (args.max_errors) |m| (if (m == 0) std.math.maxInt(usize) else m) else 100,
        }) catch |e| {
            try err_out.print("scanio: validate failed: {s}\n", .{@errorName(e)});
            try err_out.flush();
            return 1;
        };
        defer report.deinit();
        try scanio.writeReportJson(out, report);
        try out.writeByte('\n');
        try out.flush();
        return if (report.rows_invalid > 0) 1 else 0;
    }

    // Row modes stream, exactly like a scan: this is the half of an
    // import that gets written somewhere, and it must not be
    // materialized to be written.
    const want_valid = args.validate_output == .valid;
    while (v.next() catch |e| {
        try err_out.print("scanio: validate failed: {s}\n", .{@errorName(e)});
        try err_out.flush();
        return 1;
    }) |vr| {
        if (vr.isValid() == want_valid) try writeRow(out, vr.row, header, args.format);
    }
    try out.flush();
    // 0, even with rejects: this mode is a filter that did its job, and
    // failing the command would abort the very pipeline that asked for
    // the rejects. The report mode above is the gate.
    return 0;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseArgs: path only" {
    const a = try parseArgs(&.{"data.csv"});
    try testing.expectEqualStrings("data.csv", a.path);
    try testing.expect(a.where == null);
    try testing.expect(a.columns == null);
    try testing.expect(a.limit == null);
    try testing.expect(!a.count_only);
    try testing.expectEqual(Format.csv, a.format);
}

test "parseArgs: every option, in any order" {
    const a = try parseArgs(&.{ "--where", "a = 1", "data.ndjson", "--columns", "x,y", "--limit", "5", "--format", "ndjson", "--count" });
    try testing.expectEqualStrings("data.ndjson", a.path);
    try testing.expectEqualStrings("a = 1", a.where.?);
    try testing.expectEqualStrings("x,y", a.columns.?);
    try testing.expectEqual(@as(usize, 5), a.limit.?);
    try testing.expectEqual(Format.ndjson, a.format);
    try testing.expect(a.count_only);
}

test "parseArgs: a flag's value is never mistaken for the path" {
    // "--where" swallowing its argument is what keeps `--where data.csv`
    // from silently scanning nothing.
    try testing.expectError(ArgError.MissingPath, parseArgs(&.{ "--where", "a = 1" }));
    try testing.expectError(ArgError.MissingValue, parseArgs(&.{ "f.csv", "--where" }));
    try testing.expectError(ArgError.MissingValue, parseArgs(&.{ "f.csv", "--limit" }));
}

test "parseArgs: rejects what it cannot honour rather than ignoring it" {
    try testing.expectError(ArgError.UnknownFlag, parseArgs(&.{ "f.csv", "--nope" }));
    try testing.expectError(ArgError.UnknownFormat, parseArgs(&.{ "f.csv", "--format", "parquet" }));
    try testing.expectError(ArgError.BadLimit, parseArgs(&.{ "f.csv", "--limit", "many" }));
    try testing.expectError(ArgError.MissingPath, parseArgs(&.{}));
    try testing.expectError(ArgError.UnknownFlag, parseArgs(&.{ "a.csv", "b.csv" }));
}

test "parseArgs: --help short-circuits, even with a bad tail" {
    const a = try parseArgs(&.{ "--help", "--nonsense" });
    try testing.expect(a.help);
}

test "resolveColumns: names resolve to indices in the order given" {
    const header = [_][]const u8{ "id", "name", "revenue" };
    const cols = (try resolveColumns(testing.allocator, &header, "revenue, id")).?;
    defer testing.allocator.free(cols);
    try testing.expectEqualSlices(usize, &.{ 2, 0 }, cols);

    try testing.expectEqual(@as(?[]usize, null), try resolveColumns(testing.allocator, &header, null));
    try testing.expectError(error.UnknownColumn, resolveColumns(testing.allocator, &header, "id,nope"));
}

test "writeRow: CSV output re-quotes anything that would not parse back" {
    // The scanner strips quoting, so `--format csv` has to put it back or
    // `scanio a.csv | scanio -` would silently gain a column.
    const allocator = std.testing.allocator;
    var w: std.io.Writer.Allocating = .init(allocator);
    defer w.deinit();

    const fields = [_][]const u8{ "1", "Smith, John", "he said \"hi\"", "plain" };
    try writeRow(&w.writer, scanio.Row{ .fields = &fields }, &.{}, .csv);
    try std.testing.expectEqualStrings(
        "1,\"Smith, John\",\"he said \"\"hi\"\"\",plain\n",
        w.written(),
    );
}

test "parseArgs: --validate and its two row modes" {
    const a = try parseArgs(&.{ "d.csv", "--validate", "s.json" });
    try testing.expectEqualStrings("s.json", a.validate.?);
    try testing.expectEqual(ValidateOutput.report, a.validate_output);

    const b = try parseArgs(&.{ "d.csv", "--validate", "s.json", "--invalid" });
    try testing.expectEqual(ValidateOutput.invalid, b.validate_output);

    const c = try parseArgs(&.{ "d.csv", "--validate", "s.json", "--valid" });
    try testing.expectEqual(ValidateOutput.valid, c.validate_output);
}

test "parseArgs: --valid without --validate is refused, not ignored" {
    try testing.expectError(ArgError.ValidateRequired, parseArgs(&.{ "d.csv", "--valid" }));
    try testing.expectError(ArgError.MissingValue, parseArgs(&.{ "d.csv", "--validate" }));
}

test "parseArgs: --validate refuses the scan flags it cannot honour" {
    // A caller who wrote both believes the filter ran; failing says
    // otherwise before any data is written.
    try testing.expectError(ArgError.ValidateConflict, parseArgs(&.{ "d.csv", "--validate", "s.json", "--where", "a = 1" }));
    try testing.expectError(ArgError.ValidateConflict, parseArgs(&.{ "d.csv", "--validate", "s.json", "--columns", "a" }));
    try testing.expectError(ArgError.ValidateConflict, parseArgs(&.{ "d.csv", "--validate", "s.json", "--limit", "3" }));
    try testing.expectError(ArgError.ValidateConflict, parseArgs(&.{ "d.csv", "--validate", "s.json", "--count" }));
}

test "parseArgs: --max-errors, including the 'list them all' spelling" {
    const a = try parseArgs(&.{ "d.csv", "--validate", "s.json", "--max-errors", "5" });
    try testing.expectEqual(@as(usize, 5), a.max_errors.?);
    const b = try parseArgs(&.{ "d.csv", "--validate", "s.json", "--max-errors", "0" });
    try testing.expectEqual(@as(usize, 0), b.max_errors.?);
    const c = try parseArgs(&.{ "d.csv", "--validate", "s.json" });
    try testing.expect(c.max_errors == null);
    // Meaningless without --validate, so refused rather than ignored.
    try testing.expectError(ArgError.ValidateRequired, parseArgs(&.{ "d.csv", "--max-errors", "5" }));
    try testing.expectError(ArgError.BadLimit, parseArgs(&.{ "d.csv", "--validate", "s.json", "--max-errors", "x" }));
}

test "parseArgs: --not inverts the where clause" {
    const a = try parseArgs(&.{ "d.csv", "--where", "a = 1", "--not" });
    try testing.expect(a.negate);
    const b = try parseArgs(&.{ "d.csv", "--where", "a = 1" });
    try testing.expect(!b.negate);
    // --validate has its own --valid/--invalid; --not there would be a
    // second, silently-ignored way to say the same thing.
    try testing.expectError(ArgError.ValidateConflict, parseArgs(&.{ "d.csv", "--validate", "s.json", "--not" }));
}
