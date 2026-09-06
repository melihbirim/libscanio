//! WHERE-string parsing for the N-API Node binding (node_binding.zig) —
//! split into its own file specifically so it's testable via plain
//! `zig build test`, without needing Node's headers available the way
//! node_binding.zig's `@cImport(@cInclude("node_api.h"))` does.
//!
//! Grammar: "col OP val [AND col OP val ...]" where OP is one of
//! = != >= <= > <, or "col IN (a, b, c)".
const std = @import("std");
const scan = @import("scanio");
const Query = scan.Query;
const Predicate = scan.Predicate;
const Op = scan.Op;

pub fn resolveColumn(header: []const []const u8, name: []const u8) !usize {
    for (header, 0..) |h, i| {
        if (std.mem.eql(u8, h, name)) return i;
    }
    return error.UnknownColumn;
}

pub fn opFromString(s: []const u8) ?Op {
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
pub fn parseWhereString(allocator: std.mem.Allocator, header: []const []const u8, where: []const u8) ![]Predicate {
    var predicates: std.ArrayListUnmanaged(Predicate) = .{};
    errdefer predicates.deinit(allocator);
    errdefer freePredicates(allocator, predicates.items);

    var it = std.mem.splitSequence(u8, where, " AND ");
    while (it.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (part.len == 0) continue;

        // "col IN (a, b, c)" — but only when what follows " IN " really
        // is a parenthesised list. The check used to be "contains ' IN '"
        // alone, which claimed any clause whose VALUE happened to contain
        // that substring: `name = Mine IN Town` sliced "name = Mine" off
        // as the column name and failed with UnknownColumn instead of
        // parsing as name = "Mine IN Town". A non-parenthesised tail now
        // falls through to the operator scan below, where such a clause
        // belongs.
        const in_clause: ?struct { col: []const u8, inner: []const u8 } = blk: {
            const in_pos = std.mem.indexOf(u8, part, " IN ") orelse break :blk null;
            const rest = std.mem.trim(u8, part[in_pos + 4 ..], " \t");
            if (rest.len < 2 or rest[0] != '(' or rest[rest.len - 1] != ')') break :blk null;
            break :blk .{
                .col = std.mem.trim(u8, part[0..in_pos], " \t"),
                .inner = rest[1 .. rest.len - 1],
            };
        };
        if (in_clause) |ic| {
            const col_name = ic.col;
            const inner = ic.inner;
            const col = try resolveColumn(header, col_name);

            var vals: std.ArrayListUnmanaged([]const u8) = .{};
            defer vals.deinit(allocator);
            errdefer for (vals.items) |v| allocator.free(@constCast(v));
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
        // known symbols; leftmost match wins (matters when a value
        // itself contains an operator-looking substring, e.g.
        // `name = a>b`: the `=` at position 4 must win over the `>` at
        // position 7, which it does since found_op only updates on a
        // strictly earlier position).
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

/// Highest column index a set of predicates reads — the bound for
/// `QueryOptions.stop_after_column` when the caller never returns row
/// data (count()) or only ever returns one known column (aggregate()):
/// real, measured win (up to 3.6x on a low-selectivity WHERE over an
/// early column, see ROADMAP.md) from never splitting trailing columns
/// nothing will read. NOT safe for callers that return full rows
/// (scanArray()/topk()/orderBy()/streaming scan()) — bounding those
/// would silently truncate the row data they're supposed to return.
pub fn maxPredicateColumn(predicates: []const Predicate, extra_column: ?usize) ?usize {
    var max: ?usize = extra_column;
    for (predicates) |p| {
        if (max == null or p.column > max.?) max = p.column;
    }
    return max;
}

pub fn freePredicates(allocator: std.mem.Allocator, predicates: []Predicate) void {
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
pub fn parseColumnsJson(allocator: std.mem.Allocator, header: []const []const u8, columns_json: ?[]const u8) !?[]usize {
    const cj = columns_json orelse return null;
    if (cj.len == 0) return null;
    const parsed = try std.json.parseFromSlice([]const []const u8, allocator, cj, .{});
    defer parsed.deinit();
    var out = try allocator.alloc(usize, parsed.value.len);
    errdefer allocator.free(out);
    for (parsed.value, 0..) |name, i| out[i] = try resolveColumn(header, name);
    return out;
}

/// Opens a throwaway Query (no predicates) just to read the header,
/// then closes it — same two-open pattern every existing binding
/// already uses (resolve names/predicates against a probe, then open
/// for real with them applied).
pub fn probeHeader(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var probe = try Query.open(allocator, path, .{});
    defer probe.deinit();
    const h = probe.header();
    const out = try allocator.alloc([]const u8, h.len);
    for (h, 0..) |name, i| out[i] = try allocator.dupe(u8, name);
    return out;
}

pub fn freeHeader(allocator: std.mem.Allocator, header: [][]const u8) void {
    for (header) |h| allocator.free(@constCast(h));
    allocator.free(header);
}

// ── Tests ────────────────────────────────────────────────────────────
// Real adversarial coverage for a reimplementation, not just "the same
// cases the old JS regex parser happened to cover."

const testing = std.testing;

test "resolveColumn: exact match, first and last" {
    const header = [_][]const u8{ "id", "name", "revenue" };
    try testing.expectEqual(@as(usize, 0), try resolveColumn(&header, "id"));
    try testing.expectEqual(@as(usize, 2), try resolveColumn(&header, "revenue"));
}

test "resolveColumn: unknown column returns error" {
    const header = [_][]const u8{ "id", "name" };
    try testing.expectError(error.UnknownColumn, resolveColumn(&header, "nope"));
}

test "resolveColumn: case-sensitive, not a fuzzy match" {
    const header = [_][]const u8{"Name"};
    try testing.expectError(error.UnknownColumn, resolveColumn(&header, "name"));
}

test "parseWhereString: simple equality" {
    const header = [_][]const u8{ "id", "name", "revenue" };
    const preds = try parseWhereString(testing.allocator, &header, "revenue > 1000");
    defer freePredicates(testing.allocator, preds);
    try testing.expectEqual(@as(usize, 1), preds.len);
    try testing.expectEqual(@as(usize, 2), preds[0].column);
    try testing.expectEqual(Op.gt, preds[0].op);
    try testing.expectEqualStrings("1000", preds[0].value);
}

test "parseWhereString: AND joins multiple clauses" {
    const header = [_][]const u8{ "id", "name", "revenue" };
    const preds = try parseWhereString(testing.allocator, &header, "revenue > 1000 AND name = Bob");
    defer freePredicates(testing.allocator, preds);
    try testing.expectEqual(@as(usize, 2), preds.len);
    try testing.expectEqual(Op.gt, preds[0].op);
    try testing.expectEqual(Op.eq, preds[1].op);
    try testing.expectEqualStrings("Bob", preds[1].value);
}

test "parseWhereString: all six operators parse to the right Op" {
    const header = [_][]const u8{"n"};
    const cases = [_]struct { str: []const u8, op: Op }{
        .{ .str = "n = 1", .op = .eq },
        .{ .str = "n != 1", .op = .neq },
        .{ .str = "n >= 1", .op = .gte },
        .{ .str = "n <= 1", .op = .lte },
        .{ .str = "n > 1", .op = .gt },
        .{ .str = "n < 1", .op = .lt },
    };
    for (cases) |c| {
        const preds = try parseWhereString(testing.allocator, &header, c.str);
        defer freePredicates(testing.allocator, preds);
        try testing.expectEqual(c.op, preds[0].op);
    }
}

test "parseWhereString: value containing an operator-looking substring picks the leftmost real operator" {
    // "name = a>b" — the `=` at position 5 must win, not the `>` inside
    // the value at position 7. A naive "find any operator anywhere"
    // scan would misparse this as column "name = a" op ">" val "b".
    const header = [_][]const u8{"name"};
    const preds = try parseWhereString(testing.allocator, &header, "name = a>b");
    defer freePredicates(testing.allocator, preds);
    try testing.expectEqual(@as(usize, 1), preds.len);
    try testing.expectEqual(Op.eq, preds[0].op);
    try testing.expectEqualStrings("a>b", preds[0].value);
}

test "parseWhereString: >= is not misparsed as > followed by a literal =" {
    const header = [_][]const u8{"n"};
    const preds = try parseWhereString(testing.allocator, &header, "n >= 5");
    defer freePredicates(testing.allocator, preds);
    try testing.expectEqual(Op.gte, preds[0].op);
    try testing.expectEqualStrings("5", preds[0].value);
}

test "parseWhereString: extra whitespace around column/operator/value is trimmed" {
    const header = [_][]const u8{"n"};
    const preds = try parseWhereString(testing.allocator, &header, "  n   >    5   ");
    defer freePredicates(testing.allocator, preds);
    try testing.expectEqualStrings("5", preds[0].value);
}

test "parseWhereString: empty string yields zero predicates, not an error" {
    const header = [_][]const u8{"n"};
    const preds = try parseWhereString(testing.allocator, &header, "");
    defer freePredicates(testing.allocator, preds);
    try testing.expectEqual(@as(usize, 0), preds.len);
}

test "parseWhereString: unknown column in a clause returns an error" {
    const header = [_][]const u8{"n"};
    try testing.expectError(error.UnknownColumn, parseWhereString(testing.allocator, &header, "nope = 1"));
}

test "parseWhereString: garbage with no recognizable operator returns InvalidWhere" {
    const header = [_][]const u8{"n"};
    try testing.expectError(error.InvalidWhere, parseWhereString(testing.allocator, &header, "just garbage"));
}

test "parseWhereString: IN with values" {
    const header = [_][]const u8{ "id", "name" };
    const preds = try parseWhereString(testing.allocator, &header, "name IN (Alice, Bob, Carol)");
    defer freePredicates(testing.allocator, preds);
    try testing.expectEqual(@as(usize, 1), preds.len);
    try testing.expectEqual(Op.in_list, preds[0].op);
    try testing.expectEqual(@as(usize, 3), preds[0].values.len);
    try testing.expectEqualStrings("Alice", preds[0].values[0]);
    try testing.expectEqualStrings("Carol", preds[0].values[2]);
}

test "parseWhereString: IN with no values inside parens returns InvalidWhere" {
    const header = [_][]const u8{"name"};
    try testing.expectError(error.InvalidWhere, parseWhereString(testing.allocator, &header, "name IN ()"));
}

test "parseWhereString: IN missing closing paren returns InvalidWhere" {
    const header = [_][]const u8{"name"};
    try testing.expectError(error.InvalidWhere, parseWhereString(testing.allocator, &header, "name IN (Alice, Bob"));
}

test "parseWhereString: IN composes with AND" {
    const header = [_][]const u8{ "id", "name", "revenue" };
    const preds = try parseWhereString(testing.allocator, &header, "name IN (Alice, Carol) AND revenue > 1000");
    defer freePredicates(testing.allocator, preds);
    try testing.expectEqual(@as(usize, 2), preds.len);
    try testing.expectEqual(Op.in_list, preds[0].op);
    try testing.expectEqual(Op.gt, preds[1].op);
}

test "parseColumnsJson: resolves names to indices in order" {
    const header = [_][]const u8{ "id", "name", "revenue" };
    const cols = (try parseColumnsJson(testing.allocator, &header, "[\"revenue\",\"id\"]")).?;
    defer testing.allocator.free(cols);
    try testing.expectEqualSlices(usize, &.{ 2, 0 }, cols);
}

test "parseColumnsJson: null input means no projection" {
    const header = [_][]const u8{"id"};
    try testing.expectEqual(@as(?[]usize, null), try parseColumnsJson(testing.allocator, &header, null));
}

test "parseColumnsJson: unknown column name returns an error" {
    const header = [_][]const u8{"id"};
    try testing.expectError(error.UnknownColumn, parseColumnsJson(testing.allocator, &header, "[\"nope\"]"));
}

test "maxPredicateColumn: no predicates, no extra column -> null" {
    try testing.expectEqual(@as(?usize, null), maxPredicateColumn(&.{}, null));
}

test "maxPredicateColumn: extra column alone, no predicates" {
    try testing.expectEqual(@as(?usize, 5), maxPredicateColumn(&.{}, 5));
}

test "maxPredicateColumn: max across predicates, ignoring order" {
    const header = [_][]const u8{ "a", "b", "c", "d" };
    const preds = try parseWhereString(testing.allocator, &header, "d = 1 AND a = 2");
    defer freePredicates(testing.allocator, preds);
    try testing.expectEqual(@as(?usize, 3), maxPredicateColumn(preds, null));
}

test "maxPredicateColumn: extra column can exceed every predicate's column" {
    const header = [_][]const u8{ "a", "b", "c" };
    const preds = try parseWhereString(testing.allocator, &header, "a = 1");
    defer freePredicates(testing.allocator, preds);
    try testing.expectEqual(@as(?usize, 2), maxPredicateColumn(preds, 2));
}

test "maxPredicateColumn: a predicate's column can exceed the extra column" {
    const header = [_][]const u8{ "a", "b", "c" };
    const preds = try parseWhereString(testing.allocator, &header, "c = 1");
    defer freePredicates(testing.allocator, preds);
    try testing.expectEqual(@as(?usize, 2), maxPredicateColumn(preds, 0));
}

test "parseWhereString: a value containing ' IN ' is not mistaken for an IN clause" {
    // The IN branch used to fire on the substring alone, slicing
    // "name = Mine" off as the column name.
    const header = [_][]const u8{ "id", "name" };
    const preds = try parseWhereString(testing.allocator, &header, "name = Mine IN Town");
    defer freePredicates(testing.allocator, preds);

    try testing.expectEqual(@as(usize, 1), preds.len);
    try testing.expectEqual(@as(usize, 1), preds[0].column);
    try testing.expectEqual(Op.eq, preds[0].op);
    try testing.expectEqualStrings("Mine IN Town", preds[0].value);
}

test "parseWhereString: a real IN clause still parses" {
    const header = [_][]const u8{ "id", "name" };
    const preds = try parseWhereString(testing.allocator, &header, "name IN (Ann, Bob)");
    defer freePredicates(testing.allocator, preds);

    try testing.expectEqual(@as(usize, 1), preds.len);
    try testing.expectEqual(Op.in_list, preds[0].op);
    try testing.expectEqual(@as(usize, 2), preds[0].values.len);
    try testing.expectEqualStrings("Ann", preds[0].values[0]);
    try testing.expectEqualStrings("Bob", preds[0].values[1]);
}
