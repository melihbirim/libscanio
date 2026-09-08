/* Included by _native.c: native handles and direct result construction. */
typedef struct { size_t column; Slice name, rule, value; uint64_t row; } ApiFailure;
typedef int (*ApiEmit)(void *, const Slice *, size_t, const ApiFailure *, size_t, uint64_t, double, int);
typedef struct { uint64_t count; double sum, min, max, avg; int has_values; } ApiAgg;
typedef struct { uint64_t total, valid, invalid, errors; int truncated; uint64_t counts[9]; } ApiReport;
typedef struct { uint64_t total, valid, invalid, errors; } ApiStats;
extern void *py_query_open(const char *,size_t,const char *,size_t,char *);
extern void py_query_close(void *);
extern size_t py_query_ncols(void *);
extern Slice py_query_name(void *,size_t);
extern int py_query_next(void *,size_t,size_t,void *,ApiEmit,char *);
extern int py_query_count(void *,uint64_t *,char *);
extern int py_query_aggregate(void *,size_t,ApiAgg *,char *);
extern int py_query_sort(void *,size_t,size_t,int,int,void *,ApiEmit,char *);
extern void *py_columnar(void *,char *);
extern void py_columnar_close(void *);
extern size_t py_columnar_nrows(void *);
extern size_t py_columnar_ncols(void *);
extern Slice py_columnar_data(void *,size_t);
extern Slice py_columnar_offsets(void *,size_t);
extern void *py_validator_open(const char *,size_t,const char *,size_t,char *);
extern void py_validator_close(void *);
extern size_t py_validator_ncols(void *);
extern Slice py_validator_name(void *,size_t);
extern int py_validator_next(void *,size_t,size_t,void *,ApiEmit,char *);
extern int py_validator_report(void *,size_t,ApiReport *,void *,ApiEmit,char *);
extern int py_import(const char *,size_t,const char *,size_t,const char *,size_t,const char *,size_t,ApiStats *,char *);

typedef struct { void *ptr; int kind; PyObject *names; } ApiHandle;
static PyObject *api_error(const char *err) {
    if (!PyErr_Occurred()) {
        if (!strcmp(err,"OutOfMemory")) PyErr_NoMemory();
        else PyErr_SetString(PyExc_ValueError,err[0] ? err : "native operation failed");
    }
    return NULL;
}
static void api_destroy(ApiHandle *h) {
    if (!h->ptr) return;
    if (h->kind==1) py_query_close(h->ptr);
    else if (h->kind==2) py_validator_close(h->ptr);
    else py_columnar_close(h->ptr);
    h->ptr=NULL;
}
static void api_capsule_destroy(PyObject *capsule) {
    ApiHandle *h=PyCapsule_GetPointer(capsule,"libscanio.handle");
    if (h) { api_destroy(h); Py_XDECREF(h->names); PyMem_Free(h); }
}
static ApiHandle *api_handle(PyObject *obj,int kind) {
    ApiHandle *h=PyCapsule_GetPointer(obj,"libscanio.handle");
    if (!h) return NULL;
    if (!h->ptr || (kind && h->kind!=kind)) { PyErr_SetString(PyExc_ValueError,"closed or incompatible native handle"); return NULL; }
    return h;
}
static PyObject *api_wrap(void *ptr,int kind,PyObject *names) {
    ApiHandle temp={ptr,kind,NULL};
    ApiHandle *h=PyMem_Calloc(1,sizeof(*h));
    if (!h) { api_destroy(&temp); return PyErr_NoMemory(); }
    h->ptr=ptr; h->kind=kind;
    if (names) h->names=Py_NewRef(names);
    else {
        size_t n=kind==1 ? py_query_ncols(ptr) : py_validator_ncols(ptr);
        if (n>PY_SSIZE_T_MAX) { api_destroy(h); PyMem_Free(h); return PyErr_NoMemory(); }
        h->names=PyList_New((Py_ssize_t)n);
        if (h->names) for(size_t i=0;i<n;i++) {
            PyObject *s=text(kind==1 ? py_query_name(ptr,i) : py_validator_name(ptr,i));
            if (!s) { Py_CLEAR(h->names); break; }
            PyList_SET_ITEM(h->names,i,s);
        }
    }
    if (!h->names) { api_destroy(h); PyMem_Free(h); return NULL; }
    PyObject *cap=PyCapsule_New(h,"libscanio.handle",api_capsule_destroy);
    if(!cap){api_destroy(h);Py_DECREF(h->names);PyMem_Free(h);}
    return cap;
}
static PyObject *api_open_common(PyObject *args,int kind) {
    const char *path,*opts; Py_ssize_t n,m;
    if(!PyArg_ParseTuple(args,"y#y#",&path,&n,&opts,&m))return NULL;
    if(memchr(path,0,(size_t)n)){PyErr_SetString(PyExc_ValueError,"path contains NUL");return NULL;}
    char err[256]={0};
    void *p=kind==1 ? py_query_open(path,n,opts,m,err) : py_validator_open(path,n,opts,m,err);
    return p ? api_wrap(p,kind,NULL) : api_error(err);
}
static PyObject *api_open(PyObject *self,PyObject *args){(void)self;return api_open_common(args,1);}
static PyObject *api_vopen(PyObject *self,PyObject *args){(void)self;return api_open_common(args,2);}
static PyObject *api_close(PyObject *self,PyObject *obj){
    (void)self; ApiHandle *h=PyCapsule_GetPointer(obj,"libscanio.handle"); if(!h)return NULL;
    if(h->kind==3){PyErr_SetString(PyExc_ValueError,"columnar lifetime is owned by its buffers");return NULL;}
    api_destroy(h);Py_RETURN_NONE;
}
static PyObject *api_names(PyObject *self,PyObject *obj){
    (void)self;ApiHandle *h=api_handle(obj,0);if(!h)return NULL;return PyList_GetSlice(h->names,0,PyList_GET_SIZE(h->names));
}
static PyObject *api_name(ApiHandle *h,size_t i){
    while ((size_t)PyList_GET_SIZE(h->names)<=i) {
        PyObject *key=PyUnicode_FromFormat("col%zd",PyList_GET_SIZE(h->names));
        if(!key)return NULL;
        int rc=PyList_Append(h->names,key);Py_DECREF(key);if(rc<0)return NULL;
    }
    return PyList_GET_ITEM(h->names,(Py_ssize_t)i);
}
typedef struct { ApiHandle *handle; PyObject *result; int as_dict; } ApiBuild;
static PyObject *api_row(ApiBuild *b,const Slice *fields,size_t n){
    if(n>PY_SSIZE_T_MAX)return PyErr_NoMemory();
    PyObject *row=b->as_dict ? PyDict_New() : PyTuple_New((Py_ssize_t)n);
    if(!row)return NULL;
    for(size_t i=0;i<n;i++) {
        PyObject *value=text(fields[i]);if(!value){Py_DECREF(row);return NULL;}
        if(b->as_dict){
            PyObject *key=api_name(b->handle,i);
            int rc=key ? PyDict_SetItem(row,key,value) : -1;
            Py_DECREF(value);if(rc<0){Py_DECREF(row);return NULL;}
        } else PyTuple_SET_ITEM(row,(Py_ssize_t)i,value);
    }
    /* Tuples contain only immutable strings and can never acquire cycles. */
    if(!b->as_dict)PyObject_GC_UnTrack(row);
    return row;
}
static PyObject *api_errors(const ApiFailure *errors,size_t n){
    if(n>PY_SSIZE_T_MAX)return PyErr_NoMemory();
    PyObject *out=PyList_New((Py_ssize_t)n);if(!out)return NULL;
    for(size_t i=0;i<n;i++) {
        const ApiFailure *e=&errors[i];
        PyObject *col=e->column==SIZE_MAX ? Py_NewRef(Py_None) : PyLong_FromSize_t(e->column);
        PyObject *name=text(e->name),*rule=text(e->rule),*value=text(e->value),*r=NULL;
        if(col && name && rule && value)r=Py_BuildValue("{s:K,s:O,s:O,s:O,s:O}","row",(unsigned long long)e->row,"column",col,"column_name",name,"rule",rule,"value",value);
        Py_XDECREF(col);Py_XDECREF(name);Py_XDECREF(rule);Py_XDECREF(value);
        if(!r){Py_DECREF(out);return NULL;}PyList_SET_ITEM(out,(Py_ssize_t)i,r);
    }
    return out;
}
static int api_emit(void *ctx,const Slice *fields,size_t n,const ApiFailure *errors,size_t ne,uint64_t number,double key,int kind){
    (void)number;ApiBuild *b=ctx;
    if((PyList_GET_SIZE(b->result)&1023)==0 && PyErr_CheckSignals()<0)return -1;
    if(kind==3){
        PyObject *list=api_errors(errors,ne);if(!list)return -1;
        int rc=PyList_SetSlice(b->result,0,0,list);Py_DECREF(list);return rc;
    }
    PyObject *row=api_row(b,fields,n);if(!row)return -1;
    if(kind==1){
        PyObject *errs=api_errors(errors,ne);if(!errs){Py_DECREF(row);return -1;}
        PyObject *pair=PyTuple_Pack(2,row,errs);Py_DECREF(row);Py_DECREF(errs);row=pair;
        if(!row)return -1;
    }else if(kind==2){
        PyObject *v=PyFloat_FromDouble(key);if(!v){Py_DECREF(row);return -1;}
        int rc=PyDict_SetItemString(row,"_key",v);Py_DECREF(v);if(rc<0){Py_DECREF(row);return -1;}
    }
    int rc=PyList_Append(b->result,row);Py_DECREF(row);return rc;
}
static PyObject *api_next(PyObject *self,PyObject *args){
    (void)self;PyObject *cap;Py_ssize_t n,target;int dict;
    if(!PyArg_ParseTuple(args,"Onnp",&cap,&n,&target,&dict))return NULL;
    ApiHandle *h=api_handle(cap,0);if(!h)return NULL;
    if(h->kind==3 || n<1 || n>65536 || target<1){PyErr_SetString(PyExc_ValueError,"invalid batch options");return NULL;}
    PyObject *out=PyList_New(0);if(!out)return NULL;
    PyObject_GC_UnTrack(out);
    ApiBuild b={h,out,dict};char err[256]={0};
    int rc=h->kind==1 ? py_query_next(h->ptr,n,target,&b,api_emit,err) : py_validator_next(h->ptr,n,target,&b,api_emit,err);
    if(rc<0){Py_DECREF(out);api_destroy(h);return api_error(err);}
    PyObject_GC_Track(out);return out;
}
static PyObject *api_count(PyObject *self,PyObject *cap){
    (void)self;ApiHandle *h=api_handle(cap,1);if(!h)return NULL;
    char err[256]={0};uint64_t n;
    if(py_query_count(h->ptr,&n,err)<0)return api_error(err);
    return PyLong_FromUnsignedLongLong(n);
}
static PyObject *api_aggregate(PyObject *self,PyObject *args){
    (void)self;PyObject *cap;Py_ssize_t col;
    if(!PyArg_ParseTuple(args,"On",&cap,&col))return NULL;
    ApiHandle *h=api_handle(cap,1);if(!h)return NULL;
    ApiAgg r;char err[256]={0};if(col<0 || py_query_aggregate(h->ptr,(size_t)col,&r,err)<0)return api_error(err);
    PyObject *min=r.has_values ? PyFloat_FromDouble(r.min) : Py_NewRef(Py_None);
    PyObject *max=r.has_values ? PyFloat_FromDouble(r.max) : Py_NewRef(Py_None);
    PyObject *avg=r.has_values ? PyFloat_FromDouble(r.avg) : Py_NewRef(Py_None);
    PyObject *out=NULL;
    if(min && max && avg)out=Py_BuildValue("{s:K,s:d,s:O,s:O,s:O}","count",(unsigned long long)r.count,"sum",r.sum,"min",min,"max",max,"avg",avg);
    Py_XDECREF(min);Py_XDECREF(max);Py_XDECREF(avg);return out;
}
static PyObject *api_sort(PyObject *self,PyObject *args){
    (void)self;PyObject *cap;Py_ssize_t col,k;int desc,top;
    if(!PyArg_ParseTuple(args,"Onnpp",&cap,&col,&k,&desc,&top))return NULL;
    ApiHandle *h=api_handle(cap,1);if(!h)return NULL;
    if(col<0 || k<0){PyErr_SetString(PyExc_ValueError,"negative column or k");return NULL;}
    PyObject *out=PyList_New(0);if(!out)return NULL;PyObject_GC_UnTrack(out);
    ApiBuild b={h,out,1};char err[256]={0};
    if(py_query_sort(h->ptr,col,k,desc,top,&b,api_emit,err)<0){Py_DECREF(out);return api_error(err);}
    PyObject_GC_Track(out);return out;
}
static PyObject *api_columnar(PyObject *self,PyObject *cap){
    (void)self;ApiHandle *h=api_handle(cap,1);if(!h)return NULL;char err[256]={0};
    void *p=py_columnar(h->ptr,err);return p ? api_wrap(p,3,h->names) : api_error(err);
}
/* Read-only buffer protocol keeps the native columnar owner alive. */
typedef struct { PyObject_HEAD PyObject *owner; const char *data; Py_ssize_t len; } ApiBuffer;
static int api_buffer_get(PyObject *obj,Py_buffer *view,int flags){ApiBuffer *b=(ApiBuffer *)obj;return PyBuffer_FillInfo(view,obj,(void *)b->data,b->len,1,flags);}
static void api_buffer_dealloc(PyObject *obj){ApiBuffer *b=(ApiBuffer *)obj;Py_DECREF(b->owner);Py_TYPE(obj)->tp_free(obj);}
static PyBufferProcs api_buffer_protocol={api_buffer_get,NULL};
static PyTypeObject ApiBufferType={PyVarObject_HEAD_INIT(NULL,0)
    .tp_name="libscanio._native.ColumnBuffer",.tp_basicsize=sizeof(ApiBuffer),.tp_flags=Py_TPFLAGS_DEFAULT,
    .tp_dealloc=api_buffer_dealloc,.tp_as_buffer=&api_buffer_protocol};
static PyObject *api_buffer(PyObject *owner,Slice s){
    if(s.len>PY_SSIZE_T_MAX)return PyErr_NoMemory();
    ApiBuffer *b=PyObject_New(ApiBuffer,&ApiBufferType);if(!b)return NULL;
    b->owner=Py_NewRef(owner);b->data=s.len ? s.ptr : "";b->len=(Py_ssize_t)s.len;
    PyObject *out=PyMemoryView_FromObject((PyObject *)b);Py_DECREF(b);return out;
}
static PyObject *api_buffers(PyObject *self,PyObject *cap){
    (void)self;ApiHandle *h=api_handle(cap,3);if(!h)return NULL;
    size_t n=py_columnar_ncols(h->ptr),rows=py_columnar_nrows(h->ptr);
    if(n>PY_SSIZE_T_MAX)return PyErr_NoMemory();
    PyObject *out=PyList_New((Py_ssize_t)n);if(!out)return NULL;
    for(size_t i=0;i<n;i++){
        PyObject *data=api_buffer(cap,py_columnar_data(h->ptr,i));
        PyObject *offsets=api_buffer(cap,py_columnar_offsets(h->ptr,i));
        PyObject *pair=data && offsets ? PyTuple_Pack(2,offsets,data) : NULL;
        Py_XDECREF(data);Py_XDECREF(offsets);if(!pair){Py_DECREF(out);return NULL;}PyList_SET_ITEM(out,i,pair);
    }
    PyObject *r=Py_BuildValue("KN",(unsigned long long)rows,out);return r;
}
static PyObject *api_columnar_rows(PyObject *self,PyObject *args){
    (void)self;PyObject *cap;int dict;if(!PyArg_ParseTuple(args,"Op",&cap,&dict))return NULL;
    ApiHandle *h=api_handle(cap,3);if(!h)return NULL;
    size_t nr=py_columnar_nrows(h->ptr),nc=py_columnar_ncols(h->ptr);
    if(nc>SIZE_MAX/sizeof(Slice))return PyErr_NoMemory();
    Slice *data=PyMem_Calloc(nc ? nc:1,sizeof(Slice)),*off=PyMem_Calloc(nc ? nc:1,sizeof(Slice)),*fields=PyMem_Calloc(nc ? nc:1,sizeof(Slice));
    PyObject *out=PyList_New(0);
    if(!data || !off || !fields || !out){PyMem_Free(data);PyMem_Free(off);PyMem_Free(fields);Py_XDECREF(out);return PyErr_NoMemory();}
    PyObject_GC_UnTrack(out);ApiBuild b={h,out,dict};int rc=0;
    for(size_t j=0;j<nc;j++){data[j]=py_columnar_data(h->ptr,j);off[j]=py_columnar_offsets(h->ptr,j);}
    for(size_t i=0;i<nr;i++){
        for(size_t j=0;j<nc;j++){
            const uint32_t *offsets=(const uint32_t *)off[j].ptr;
            size_t len=offsets[i+1]-offsets[i];
            fields[j]=(Slice){len ? data[j].ptr+offsets[i] : "",len};
        }
        if(api_emit(&b,fields,nc,NULL,0,0,0,0)<0){rc=-1;break;}
    }
    PyMem_Free(data);PyMem_Free(off);PyMem_Free(fields);
    if(rc<0){Py_DECREF(out);return NULL;}PyObject_GC_Track(out);return out;
}
static PyObject *api_report(PyObject *self,PyObject *args){
    (void)self;PyObject *cap;Py_ssize_t max;
    if(!PyArg_ParseTuple(args,"On",&cap,&max))return NULL;
    ApiHandle *h=api_handle(cap,2);if(!h)return NULL;
    if(max<0){PyErr_SetString(PyExc_ValueError,"max_errors must be non-negative");return NULL;}
    PyObject *errors=PyList_New(0);if(!errors)return NULL;
    ApiBuild b={h,errors,0};char err[256]={0};ApiReport r;
    if(py_validator_report(h->ptr,max,&r,&b,api_emit,err)<0){Py_DECREF(errors);return api_error(err);}
    const char *keys[]={"too_few_fields","too_many_fields","missing_required","bad_type","below_min","above_max","too_short","too_long","not_in_set"};
    PyObject *counts=PyDict_New();if(!counts){Py_DECREF(errors);return NULL;}
    for(size_t i=0;i<9;i++)if(r.counts[i]){
        PyObject *n=PyLong_FromUnsignedLongLong(r.counts[i]);int rc=n ? PyDict_SetItemString(counts,keys[i],n) : -1;
        Py_XDECREF(n);if(rc<0){Py_DECREF(counts);Py_DECREF(errors);return NULL;}
    }
    PyObject *out=Py_BuildValue("{s:K,s:K,s:K,s:K,s:O,s:O,s:O}","rows_total",(unsigned long long)r.total,"rows_valid",(unsigned long long)r.valid,"rows_invalid",(unsigned long long)r.invalid,"errors_total",(unsigned long long)r.errors,"truncated",r.truncated ? Py_True:Py_False,"counts",counts,"errors",errors);
    Py_DECREF(counts);Py_DECREF(errors);return out;
}
static PyObject *api_import(PyObject *self,PyObject *args){
    (void)self;const char *p,*s,*g,*b;Py_ssize_t np,ns,ng,nb;
    if(!PyArg_ParseTuple(args,"y#y#y#y#",&p,&np,&s,&ns,&g,&ng,&b,&nb))return NULL;
    char err[256]={0};ApiStats r;
    if(py_import(p,np,s,ns,g,ng,b,nb,&r,err)<0)return api_error(err);
    return Py_BuildValue("{s:K,s:K,s:K,s:K}","rows_total",(unsigned long long)r.total,"rows_valid",(unsigned long long)r.valid,"rows_invalid",(unsigned long long)r.invalid,"errors_total",(unsigned long long)r.errors);
}
#define API_METHODS \
    {"query_open",api_open,METH_VARARGS,NULL}, \
    {"validator_open",api_vopen,METH_VARARGS,NULL}, \
    {"close",api_close,METH_O,NULL}, \
    {"names",api_names,METH_O,NULL}, \
    {"next_batch",api_next,METH_VARARGS,NULL}, \
    {"count",api_count,METH_O,NULL}, \
    {"aggregate",api_aggregate,METH_VARARGS,NULL}, \
    {"sort",api_sort,METH_VARARGS,NULL}, \
    {"columnar",api_columnar,METH_O,NULL}, \
    {"columnar_buffers",api_buffers,METH_O,NULL}, \
    {"columnar_rows",api_columnar_rows,METH_VARARGS,NULL}, \
    {"report",api_report,METH_VARARGS,NULL}, \
    {"validate_to_files",api_import,METH_VARARGS,NULL},
