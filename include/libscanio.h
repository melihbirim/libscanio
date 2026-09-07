#ifndef LIBSCANIO_H
#define LIBSCANIO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct scanio_scanner scanio_t;

typedef enum {
    SCANIO_EQ = 0,
    SCANIO_NEQ = 1,
    SCANIO_GT = 2,
    SCANIO_GTE = 3,
    SCANIO_LT = 4,
    SCANIO_LTE = 5,
    SCANIO_IN = 6,
} scanio_op_t;

typedef struct {
    size_t column;
    scanio_op_t op;
    const char *value;   /* null-terminated; used for every op except IN — pass "" for IN */
    const char **values; /* only used when op == SCANIO_IN: matches if the field equals ANY of these */
    size_t n_values;
} scanio_predicate_t;

typedef struct {
    const size_t *columns;   /* nullable: column indices to project, in order */
    size_t n_columns;
    const scanio_predicate_t *where; /* nullable: implicitly AND-ed */
    size_t n_where;
    long long limit;         /* -1 = no limit */
    /* Highest column index you will ever read from this scan (max of
     * every WHERE predicate's column, every projected column, and
     * anything else you'll read via the row). -1 = don't know / need
     * every column (safe default). Set this whenever you know the
     * bound: measured up to 3.6x faster on a low-selectivity WHERE over
     * an early column, since trailing unneeded fields are never split
     * at all. */
    long long max_column;
} scanio_options_t;

/* Opens a CSV file for scanning. Returns NULL on error — call
 * scanio_last_error() for a human-readable reason. */
scanio_t *scanio_open(const char *path, const scanio_options_t *options);

/* Returns the column index for `name`, or SIZE_MAX if not found. */
size_t scanio_column_index(scanio_t *scanner, const char *name);

/* Number of columns in the header. */
size_t scanio_n_columns(scanio_t *scanner);

/* Column name at `index`, or NULL if out of range. Valid for the
 * scanner's lifetime — unlike row fields, header names are not
 * invalidated by the next scanio_next() call. */
const char *scanio_column_name(scanio_t *scanner, size_t index);

/* Advances to the next matching row.
 * Returns 1 with out_fields and out_n set (valid until the next call), 0
 * at EOF/limit reached, or -1 on error (call scanio_last_error()). */
int scanio_next(scanio_t *scanner, const char ***out_fields, size_t *out_n);

/* Row count. With no WHERE predicates in the options this file was opened
 * with, this is a fast path that never parses a single field. */
long long scanio_count(scanio_t *scanner);

typedef struct {
    unsigned long long count;
    double sum;
    double min;
    double max;
    double avg;
    /* 0 if no numeric values were seen (count == 0) — min/max/avg above
     * are meaningless in that case, check this first. */
    int has_values;
} scanio_agg_t;

/* Aggregates count/sum/min/max/avg over `column` for the REST of this
 * scanner's rows — same "drains the scanner" semantics as scanio_count().
 * Composes with whatever WHERE/columns/limit the scanner was opened with.
 * Returns 0 on success (out filled in), -1 on error. */
int scanio_aggregate(scanio_t *scanner, size_t column, scanio_agg_t *out);

typedef struct scanio_topk_result scanio_topk_t;

/* Runs top-K over the REST of this scanner's rows (drains it, same as
 * scanio_aggregate()/scanio_count()) and returns a handle to walk the K
 * results via scanio_topk_next(). `descending` is a boolean (0 or 1).
 * Returns NULL on error — call scanio_last_error(). */
scanio_topk_t *scanio_topk(scanio_t *scanner, size_t column, size_t k, int descending);

/* Walks the sorted top-K results, best-to-worst, one at a time — same
 * call shape as scanio_next(). out_key receives that row's sort key (the
 * numeric value of the column top-K was run on). */
int scanio_topk_next(scanio_topk_t *tk, const char ***out_fields, size_t *out_n, double *out_key);

void scanio_topk_close(scanio_topk_t *tk);

typedef struct scanio_collect_result scanio_collect_t;

/* Runs the REST of this scanner's rows to completion (drains it, same as
 * scanio_count()/scanio_aggregate()/scanio_topk()) and packs every
 * matching row's fields into ONE contiguous NUL-separated buffer,
 * row-major (n_rows * n_cols fields total). Exists so a caller can fetch
 * an entire result set in a single bulk copy instead of one small call
 * per field per row — that per-call crossing cost, not the scan itself,
 * is what dominates when a caller (e.g. Python via ctypes) wants every
 * matching row back as real objects. Returns NULL on error. */
scanio_collect_t *scanio_collect(scanio_t *scanner);

/* Pointer to the packed buffer plus its length in bytes. NULL/0 if there
 * were no matching rows. Valid until scanio_collect_close() — copy it
 * out immediately rather than holding the pointer. */
const char *scanio_collect_data(scanio_collect_t *cr, size_t *out_len);

size_t scanio_collect_n_rows(scanio_collect_t *cr);
size_t scanio_collect_n_cols(scanio_collect_t *cr);

void scanio_collect_close(scanio_collect_t *cr);

void scanio_close(scanio_t *scanner);

/* ── Import validation ──────────────────────────────────────────────
 *
 * The question an import asks is not "which rows do I want" but "which
 * rows can I not take, and why". Rules come in as a JSON schema keyed by
 * column name and are parsed and evaluated inside the library, so every
 * binding gets the same answer:
 *
 *   {"id":     {"type": "integer", "required": true},
 *    "amount": {"type": "float", "min": 0},
 *    "status": {"one_of": ["new", "paid"]},
 *    "email":  {"required": true, "max_len": 255}}
 *
 * type is one of any/integer/float/boolean/datetime/string. Every key
 * must name a real column and every rule name must be spelled right —
 * both are errors, because a rule that silently does not run is worse
 * than a call that fails. */

typedef struct scanio_validation scanio_validation_t;

/* One pass over the file, returning a summary. max_errors bounds how
 * many individual errors the report STORES (0 = default 100); every
 * error is counted regardless, so a wholly-broken file yields a report
 * rather than an allocation the size of the file.
 * Returns NULL on error — call scanio_last_error(). */
scanio_validation_t *scanio_validate(const char *path, const char *schema_json,
                                     size_t max_errors);

/* The report, as JSON. Valid until scanio_validate_free():
 *
 *   {"rows_total": 5, "rows_valid": 3, "rows_invalid": 2,
 *    "errors_total": 4, "truncated": false,
 *    "counts": {"bad_type": 2, "missing_required": 2},
 *    "errors": [{"row": 1, "column": 0, "column_name": "id",
 *                "rule": "bad_type", "value": "abc"}]}
 *
 * "column" is null for a structural error (too_few_fields /
 * too_many_fields), which is about the row rather than one cell. */
const char *scanio_validate_json(scanio_validation_t *v);

void scanio_validate_free(scanio_validation_t *v);

typedef struct scanio_validator scanio_validator_t;

/* Streaming validation: every row handed back with its failures
 * attached, so a caller writes the good rows to its target and the bad
 * ones to a rejects file in the same pass, never materializing either.
 * Returns NULL on error. */
scanio_validator_t *scanio_validator_open(const char *path, const char *schema_json);

/* 1 = row produced, 0 = end of file, -1 = error. *out_errors_json is set
 * to NULL for a valid row — the common case, and the one that stays
 * allocation-free. When non-NULL it is a JSON array of the same error
 * objects scanio_validate_json() emits, valid until the next call.
 * out_row_number receives the 1-based data row number (header excluded).
 * Any out pointer may be NULL. */
int scanio_validator_next(scanio_validator_t *v, const char ***out_fields,
                          size_t *out_n, const char **out_errors_json,
                          uint64_t *out_row_number);

/* Running totals, meaningful at any point and final once next() has
 * returned 0. */
uint64_t scanio_validator_rows_total(scanio_validator_t *v);
uint64_t scanio_validator_rows_valid(scanio_validator_t *v);
uint64_t scanio_validator_rows_invalid(scanio_validator_t *v);
size_t scanio_validator_n_columns(scanio_validator_t *v);

/* Header column name at `index`, or NULL if out of range. Valid until
 * scanio_validator_close(). */
const char *scanio_validator_column_name(scanio_validator_t *v, size_t index);

void scanio_validator_close(scanio_validator_t *v);

/* Human-readable reason for the most recent NULL/-1 return on this
 * thread, or NULL if the last call succeeded. The returned pointer is
 * only valid until the next libscanio call on this thread — copy it if
 * you need to keep it. */
const char *scanio_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* LIBSCANIO_H */
