# Serial input limits

The Zig `Scanner`, `NdjsonScanner`, and `Query` APIs accept opt-in input
limits. Existing callers default to `InputLimits.unlimited` for compatibility.

```zig
var query = try scanio.Query.open(allocator, path, .{
    .limits = scanio.InputLimits.recommended,
});
defer query.deinit();
```

The recommended profile permits records up to 16 MiB and up to 4,096 fields.
For custom limits, use `.limits = .{ .max_record_bytes = 1024 * 1024,
.max_fields = 256 }`. Each `null` value independently disables that limit;
zero permits no bytes or fields. Limits are inclusive.

- CSV and NDJSON record bytes include everything before LF, including CR
  in CRLF. JSON-array record bytes include the object's braces but exclude
  surrounding separators. CSV remains line-oriented; multiline CSV is unsupported.
- CSV fields and top-level JSON members count toward `max_fields`. JSON
  members outside the first record's schema also count; nested members do not.
- Headers and consumed records are checked. Projection cannot hide excess
  fields, and counts use the scanner when limits are enabled. A query limit
  stops consumption; records after that stopping point are not checked.
- Violations return `error.RecordTooLarge` or `error.TooManyFields`.
  After a scan-time limit failure, subsequent `next()` and `countRemaining()`
  calls return that same error. Close the scanner to release resources.

Record size is checked before growing record scratch storage; field count
is checked before decoding or storing excess fields. These limits do not
replace syntax validation or existing JSON parser token limits. They do not
cap total process memory: read buffers, allocation capacity, retained results,
and other application allocations remain separate costs.

This first implementation covers serial Zig APIs only. Parallel readers and
the C, Python, Node, CLI, and MCP interfaces do not yet expose these settings.
