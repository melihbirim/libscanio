#ifndef LIBSCANIO_H
#define LIBSCANIO_H

#include <stddef.h>

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

/* Human-readable reason for the most recent NULL/-1 return on this
 * thread, or NULL if the last call succeeded. The returned pointer is
 * only valid until the next libscanio call on this thread — copy it if
 * you need to keep it. */
const char *scanio_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* LIBSCANIO_H */
