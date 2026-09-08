#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <stdint.h>

typedef struct { const char *ptr; size_t len; } Slice;
typedef struct { size_t column; Slice name, rule, value; } Failure;
typedef int (*Emit)(void *, const Slice *, size_t, const Failure *, size_t);
typedef int (*Poll)(void *);
extern int scanio_python_validate(const char *, size_t, const char *, size_t,
    int, int, void *, Emit, Poll, char *, size_t);

static PyObject *text(Slice s) {
    if (s.len > PY_SSIZE_T_MAX) { PyErr_NoMemory(); return NULL; }
    return PyUnicode_DecodeUTF8(s.ptr, (Py_ssize_t)s.len, "strict");
}

typedef struct {
    PyObject *result, *keys[6], **names, *empty_name;
    size_t names_len, rule_count;
    const char *rule_ptrs[9];
    PyObject *rules[9];
} Context;

static PyObject *rule_name(Context *ctx, Slice s) {
    /* Rule strings are immutable static slices in Zig, stable for the call. */
    for (size_t i = 0; i < ctx->rule_count; i++)
        if (ctx->rule_ptrs[i] == s.ptr) return Py_NewRef(ctx->rules[i]);
    PyObject *value = text(s);
    if (!value) return NULL;
    if (ctx->rule_count < 9) {
        size_t i = ctx->rule_count++;
        ctx->rule_ptrs[i] = s.ptr;
        ctx->rules[i] = Py_NewRef(value);
    }
    return value;
}

static void clear_context(Context *ctx) {
    for (size_t i = 0; i < 6; i++) Py_XDECREF(ctx->keys[i]);
    for (size_t i = 0; i < ctx->names_len; i++) Py_XDECREF(ctx->names[i]);
    for (size_t i = 0; i < ctx->rule_count; i++) Py_DECREF(ctx->rules[i]);
    PyMem_Free(ctx->names);
    Py_XDECREF(ctx->empty_name);
}

static int emit(void *opaque, const Slice *fields, size_t nf, const Failure *errors, size_t ne) {
    Context *ctx = (Context *)opaque;
    PyObject *values = NULL, *failures = NULL, *row = NULL;
    if (nf > PY_SSIZE_T_MAX || ne > PY_SSIZE_T_MAX) { PyErr_NoMemory(); return -1; }
    if (nf > ctx->names_len) {
        if (nf > SIZE_MAX / sizeof(PyObject *)) { PyErr_NoMemory(); return -1; }
        PyObject **names = PyMem_Realloc(ctx->names, nf * sizeof(PyObject *));
        if (!names) { PyErr_NoMemory(); return -1; }
        for (size_t i = ctx->names_len; i < nf; i++) names[i] = NULL;
        ctx->names = names;
        ctx->names_len = nf;
    }
    values = PyList_New((Py_ssize_t)nf);
    failures = PyList_New((Py_ssize_t)ne);
    if (!values || !failures) goto fail;
    /* These private containers cannot form cycles during construction.
     * Track them before publication, avoiding GC rescanning the growing result. */
    PyObject_GC_UnTrack(values);
    PyObject_GC_UnTrack(failures);
    for (size_t i = 0; i < nf; i++) {
        PyObject *value = text(fields[i]);
        if (!value) goto fail;
        PyList_SET_ITEM(values, (Py_ssize_t)i, value); /* steals */
    }
    for (size_t i = 0; i < ne; i++) {
        const Failure *e = &errors[i];
        PyObject *column = e->column == SIZE_MAX ? Py_NewRef(Py_None) : PyLong_FromSize_t(e->column);
        PyObject **cached_name = e->column < ctx->names_len ? &ctx->names[e->column] : &ctx->empty_name;
        if (!*cached_name) *cached_name = text(e->name);
        PyObject *name = Py_XNewRef(*cached_name), *rule = rule_name(ctx, e->rule), *value = NULL;
        /* Reuse the row's string when the error refers to that exact value. */
        if (e->column < nf && e->value.ptr == fields[e->column].ptr && e->value.len == fields[e->column].len)
            value = Py_NewRef(PyList_GET_ITEM(values, (Py_ssize_t)e->column));
        else value = text(e->value);
        PyObject *error = NULL;
        if (column && name && rule && value) {
            error = PyDict_New();
            if (error && (PyDict_SetItem(error, ctx->keys[2], column) < 0 ||
                PyDict_SetItem(error, ctx->keys[3], name) < 0 ||
                PyDict_SetItem(error, ctx->keys[4], rule) < 0 ||
                PyDict_SetItem(error, ctx->keys[5], value) < 0)) Py_CLEAR(error);
        }
        Py_XDECREF(column); Py_XDECREF(name); Py_XDECREF(rule); Py_XDECREF(value);
        if (!error) goto fail;
        PyList_SET_ITEM(failures, (Py_ssize_t)i, error);
    }
    row = PyDict_New();
    if (!row || PyDict_SetItem(row, ctx->keys[0], values) < 0 ||
        PyDict_SetItem(row, ctx->keys[1], failures) < 0 || PyList_Append(ctx->result, row) < 0) goto fail;
    PyObject_GC_UnTrack(row);
    Py_DECREF(row); Py_DECREF(values); Py_DECREF(failures);
    return 0;
fail:
    Py_XDECREF(row); Py_XDECREF(values); Py_XDECREF(failures);
    return -1;
}

static int poll_signals(void *ctx) { (void)ctx; return PyErr_CheckSignals(); }

static PyObject *validate(PyObject *self, PyObject *args) {
    (void)self;
    PyObject *input, *schema;
    int format, full;
    if (!PyArg_ParseTuple(args, "O!O!ii", &PyBytes_Type, &input, &PyBytes_Type, &schema, &format, &full)) return NULL;
    if (format < 0 || format > 2 || (full != 0 && full != 1)) {
        PyErr_SetString(PyExc_ValueError, "invalid validation options"); return NULL;
    }
    PyObject *result = full ? PyList_New(0) : NULL;
    if (full && !result) return NULL;
    if (full) PyObject_GC_UnTrack(result);
    Context ctx = {0};
    ctx.result = result;
    if (full) {
        const char *keys[] = {"values", "errors", "column", "column_name", "rule", "value"};
        for (size_t i = 0; i < 6; i++) ctx.keys[i] = PyUnicode_FromString(keys[i]);
        if (!ctx.keys[0] || !ctx.keys[1] || !ctx.keys[2] || !ctx.keys[3] || !ctx.keys[4] || !ctx.keys[5]) {
            clear_context(&ctx); Py_DECREF(result); return NULL;
        }
    }
    char error[256] = {0};
    /* Hold the GIL: emit constructs objects directly, and polls service signals. */
    int status = scanio_python_validate(PyBytes_AS_STRING(input), (size_t)PyBytes_GET_SIZE(input),
        PyBytes_AS_STRING(schema), (size_t)PyBytes_GET_SIZE(schema), format, full,
        &ctx, emit, poll_signals, error, sizeof error);
    if (status < 0) {
        clear_context(&ctx);
        Py_XDECREF(result);
        if (!PyErr_Occurred()) {
            if (strcmp(error, "OutOfMemory") == 0) PyErr_NoMemory();
            else PyErr_SetString(PyExc_ValueError, error[0] ? error : "validation failed");
        }
        return NULL;
    }
    if (full) {
        /* All values are native-created strings and errors contain scalars.
         * Lists/dicts become mutable by callers only after this publication. */
        for (Py_ssize_t i = 0; i < PyList_GET_SIZE(result); i++) {
            PyObject *row = PyList_GET_ITEM(result, i);
            PyObject_GC_Track(PyDict_GetItem(row, ctx.keys[0]));
            PyObject_GC_Track(PyDict_GetItem(row, ctx.keys[1]));
            PyObject_GC_Track(row);
        }
        PyObject_GC_Track(result);
        clear_context(&ctx);
        return result;
    }
    clear_context(&ctx);
    return PyBool_FromLong(status);
}

extern const char *scanio_python_build_mode(void);
static PyObject *build_mode(PyObject *self, PyObject *ignored) {
    (void)self; (void)ignored;
    return PyUnicode_FromString(scanio_python_build_mode());
}

#include "_api.c"

static PyMethodDef methods[] = {
    API_METHODS
    {"build_mode", build_mode, METH_NOARGS, "Optimization mode of the statically linked Zig validator."},
    {"validate", validate, METH_VARARGS, "Validate borrowed bytes/path; build only rejected Python rows."},
    {NULL, NULL, 0, NULL}
};
static struct PyModuleDef module = {PyModuleDef_HEAD_INIT, "_native", NULL, -1, methods};
PyMODINIT_FUNC PyInit__native(void) {
    if (PyType_Ready(&ApiBufferType) < 0) return NULL;
    return PyModule_Create(&module);
}
