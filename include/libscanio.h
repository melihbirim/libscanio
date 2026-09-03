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
} scanio_op_t;

typedef struct {
    size_t column;
    scanio_op_t op;
    const char *value; /* null-terminated */
} scanio_predicate_t;

typedef struct {
    const size_t *columns;   /* nullable: column indices to project, in order */
    size_t n_columns;
    const scanio_predicate_t *where; /* nullable: implicitly AND-ed */
    size_t n_where;
    long long limit;         /* -1 = no limit */
} scanio_options_t;

/* Opens a CSV file for scanning. Returns NULL on error — call
 * scanio_last_error() for a human-readable reason. */
scanio_t *scanio_open(const char *path, const scanio_options_t *options);

/* Returns the column index for `name`, or SIZE_MAX if not found. */
size_t scanio_column_index(scanio_t *scanner, const char *name);

/* Advances to the next matching row.
 * Returns 1 with out_fields and out_n set (valid until the next call), 0
 * at EOF/limit reached, or -1 on error (call scanio_last_error()). */
int scanio_next(scanio_t *scanner, const char ***out_fields, size_t *out_n);

/* Row count. With no WHERE predicates in the options this file was opened
 * with, this is a fast path that never parses a single field. */
long long scanio_count(scanio_t *scanner);

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
