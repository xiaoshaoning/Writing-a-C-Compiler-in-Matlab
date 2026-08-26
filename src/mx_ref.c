/* mx_ref.c — standalone native mx/mex runtime for the GCC reference
 * track of mex_run.
 *
 * The matlabcc oracle (cc_int + x86sim) and this file implement ONE
 * contract (docs/2026-08-16-mex-support-plan.md §6).  The oracle
 * compiles the mex source with cc_int and emulates every mx/mex call
 * as a shim; the reference track compiles the SAME assembled code
 * (preprocessed-identical source, plus this file) with real gcc and
 * runs it natively, so the two tracks can be cross-checked on the
 * same inputs and must produce identical plhs.
 *
 * Compiled as part of the mex_run(...,'gcc') assembly:
 *
 *     [std includes + type decls] + [this file] + [mex source] + [harness main]
 *
 * The harness protocol (text, one input per line on the exe's stdin
 * via an input file, one output per line on its stdout via an output
 * file):
 *
 *     N <nrhs>
 *     D  <rank> <d0..d(r-1)> <v...>              double real, column-major
 *     Z  <rank> <d0..d(r-1)> <re...> <im...>     double complex
 *     C  <len> <raw chars...>                    char row vector
 *     L  <rank> <d0..d(r-1)> <v...>              logical
 *     I  <rank> <d0..d(r-1)> <v...>              int32
 *     CE <nelem> <elem specs...>                 cell (row)
 *     ST <nfields> <fname...> <field specs...>   1x1 struct
 *     SP <m> <n> <nzmax> <ir...> <jc...> <pr...> sparse double real
 *
 * Doubles dump with %.17g (exact round-trip through strtod on the
 * MATLAB side).  Char content is length-prefixed raw text with no
 * embedded newlines.
 *
 * The mxArray layout matches the documented ABI offsets exactly so the
 * two tracks stay comparable (magic +0, class +8, flags +16, rank +24,
 * dims[3] +32/40/48, pr +56, pi +64, refcount +72, struct nfields +80 /
 * fieldnames +88, sparse nzmax +96 / ir +104 / jc +112, cells +120).
 */

#ifndef MX_REF_C
#define MX_REF_C

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdarg.h>

#define MX_MAGIC ((uint64_t)0x4D584152ULL)
#define MXF_COMPLEX 2
#define MXF_SPARSE  8

struct mxArray_tag {
	uint64_t  magic;      /* +0   'MXAR' sanity             */
	int64_t   class_id;   /* +8   mxClassID                 */
	int64_t   flags;      /* +16  complex / sparse / global */
	int64_t   rank;       /* +24  ndims                     */
	int64_t   dims[3];    /* +32 +40 +48                    */
	void     *pr;         /* +56  data                      */
	void     *pi;         /* +64  imag data (0 if none)     */
	int64_t   refcount;   /* +72                            */
	int64_t   nfields;    /* +80  struct: field count       */
	char    **fieldnames; /* +88  struct: field name table  */
	int64_t   nzmax;      /* +96  sparse: capacity          */
	mwIndex  *ir;         /* +104 sparse: row indexes       */
	mwIndex  *jc;         /* +112 sparse: column starts     */
	mxArray **cells;      /* +120 cell/struct element table */
};

static const char *mx_ref_current_mex = "mexFunction";
static int mx_ref_locked = 0;

/* Forward declarations (definitions below are ordered by category; the
   corpus sources are appended after this file and call every entry). */
mxArray *mxCreateDoubleMatrix(mwSize, mwSize, mxComplexity);
mxArray *mxCreateDoubleScalar(double);
mxArray *mxCreateNumericMatrix(mwSize, mwSize, mxClassID, mxComplexity);
mxArray *mxCreateNumericArray(mwSize, const mwSize *, mxClassID, mxComplexity);
mxArray *mxCreateString(const char *);
mxArray *mxCreateCharArray(mwSize, mwSize);
mxArray *mxCreateCharMatrixFromStrings(mwSize, const char **);
mxArray *mxCreateLogicalMatrix(mwSize, mwSize);
mxArray *mxCreateLogicalScalar(mxLogical);
mxArray *mxCreateCellMatrix(mwSize, mwSize);
mxArray *mxCreateStructMatrix(mwSize, mwSize, int, const char **);
mxArray *mxCreateSparse(mwSize, mwSize, mwSize, mxComplexity);
double *mxGetPr(const mxArray *);
double *mxGetPi(const mxArray *);
void *mxGetData(const mxArray *);
double *mxGetDoubles(const mxArray *);
double *mxGetComplexDoubles(const mxArray *);
double mxGetScalar(const mxArray *);
mwSize mxGetM(const mxArray *);
mwSize mxGetN(const mxArray *);
mwSize mxGetNumberOfElements(const mxArray *);
const mwSize *mxGetDimensions(const mxArray *);
mwSize mxGetNumberOfDimensions(const mxArray *);
mxClassID mxGetClassID(const mxArray *);
const char *mxGetClassName(const mxArray *);
mwSize mxGetElementSize(const mxArray *);
mxChar *mxGetChars(const mxArray *);
int mxGetString(const mxArray *, char *, mwSize);
char *mxArrayToString(const mxArray *);
mwIndex *mxGetIr(const mxArray *);
mwIndex *mxGetJc(const mxArray *);
mwSize mxGetNzmax(const mxArray *);
mxArray *mxGetCell(const mxArray *, mwIndex);
mxArray *mxGetField(const mxArray *, mwIndex, const char *);
int mxGetNumberOfFields(const mxArray *);
const char *mxGetFieldNameByNumber(const mxArray *, int);
int mxGetFieldNumber(const mxArray *, const char *);
mwIndex mxCalcSingleSubscript(const mxArray *, mwSize, const mwIndex *);
int mxIsDouble(const mxArray *);
int mxIsSingle(const mxArray *);
int mxIsChar(const mxArray *);
int mxIsCell(const mxArray *);
int mxIsStruct(const mxArray *);
int mxIsLogical(const mxArray *);
int mxIsSparse(const mxArray *);
int mxIsComplex(const mxArray *);
int mxIsEmpty(const mxArray *);
int mxIsScalar(const mxArray *);
int mxIsNumeric(const mxArray *);
int mxIsClass(const mxArray *, const char *);
int mxIsInt32(const mxArray *);
int mxIsNaN(double);
int mxIsInf(double);
int mxIsFinite(double);
int mxIsLogicalScalar(const mxArray *);
int mxIsLogicalScalarTrue(const mxArray *);
double mxGetEps(void);
double mxGetInf(void);
double mxGetNaN(void);
void mxSetPr(mxArray *, double *);
void mxSetPi(mxArray *, double *);
void mxSetData(mxArray *, void *);
void mxSetIr(mxArray *, mwIndex *);
void mxSetJc(mxArray *, mwIndex *);
void mxSetCell(mxArray *, mwIndex, mxArray *);
void mxSetField(mxArray *, mwIndex, const char *, mxArray *);
void mxSetClassName(mxArray *, const char *);
void *mxMalloc(size_t);
void *mxCalloc(size_t, size_t);
void *mxRealloc(void *, size_t);
void mxFree(void *);
void mxDestroyArray(mxArray *);
mxArray *mxDuplicateArray(const mxArray *);
int mxAddField(mxArray *, const char *);
void mxRemoveField(mxArray *, int);
void mxAssert(int, const char *);
int mexPrintf(const char *, ...);
void mexErrMsgIdAndTxt(const char *, const char *, ...);
void mexWarnMsgIdAndTxt(const char *, const char *, ...);
void mexLock(void);
void mexUnlock(void);
int mexIsLocked(void);
void mexMakeArrayPersistent(mxArray *);
void mexMakeMemoryPersistent(void *);
const char *mexFunctionName(void);
int mexCallMATLAB(int, mxArray **, int, mxArray **, const char *);
int mexEvalString(const char *);
mxArray *mexGetVariable(const char *, const char *);

static int64_t mx_ref_numel(const mxArray *a)
{
	int64_t n = 1;
	for (int64_t i = 0; i < a->rank && i < 3; i++)
		n *= a->dims[i];
	return n;
}

static int64_t mx_ref_elem_size(int64_t cls)
{
	switch (cls) {
	case mxDOUBLE_CLASS:
	case mxINT64_CLASS:
	case mxUINT64_CLASS:
		return 8;
	case mxSINGLE_CLASS:
	case mxINT32_CLASS:
	case mxUINT32_CLASS:
		return 4;
	case mxCHAR_CLASS:
	case mxLOGICAL_CLASS:
	case mxINT8_CLASS:
	case mxUINT8_CLASS:
		return 1;
	case mxINT16_CLASS:
	case mxUINT16_CLASS:
		return 2;
	default:
		return 8;
	}
}

static mxArray *mx_ref_new(int64_t cls, int64_t rank, const int64_t *dims)
{
	mxArray *a = (mxArray *) calloc(1, sizeof(mxArray));
	if (!a) return NULL;
	a->magic = MX_MAGIC;
	a->class_id = cls;
	a->rank = rank;
	for (int64_t i = 0; i < rank && i < 3; i++)
		a->dims[i] = dims[i] > 0 ? dims[i] : 1;
	return a;
}

/* ---------------------------------------------------------------- */
/* mxCreate*                                                         */
/* ---------------------------------------------------------------- */

mxArray *
mxCreateDoubleMatrix(mwSize m, mwSize n, mxComplexity c)
{
	int64_t d[3] = { (int64_t) m, (int64_t) n, 1 };
	mxArray *a = mx_ref_new(mxDOUBLE_CLASS, 2, d);
	if (!a) return NULL;
	int64_t k = (int64_t) m * n;
	a->pr = calloc(k > 0 ? (size_t) k : 1, sizeof(double));
	if (c == mxCOMPLEX)
		a->pi = calloc(k > 0 ? (size_t) k : 1, sizeof(double));
	if (c == mxCOMPLEX) a->flags |= MXF_COMPLEX;
	return a;
}

mxArray *
mxCreateDoubleScalar(double v)
{
	int64_t d[3] = { 1, 1, 1 };
	mxArray *a = mx_ref_new(mxDOUBLE_CLASS, 2, d);
	if (!a) return NULL;
	a->pr = calloc(1, sizeof(double));
	((double *) a->pr)[0] = v;
	return a;
}

mxArray *
mxCreateNumericMatrix(mwSize m, mwSize n, mxClassID cls, mxComplexity c)
{
	int64_t d[3] = { (int64_t) m, (int64_t) n, 1 };
	mxArray *a = mx_ref_new((int64_t) cls, 2, d);
	if (!a) return NULL;
	int64_t k = (int64_t) m * n;
	size_t es = (size_t) mx_ref_elem_size((int64_t) cls);
	a->pr = calloc(k > 0 ? (size_t) k : 1, es);
	if (c == mxCOMPLEX) {
		a->pi = calloc(k > 0 ? (size_t) k : 1, es);
		a->flags |= MXF_COMPLEX;
	}
	return a;
}

mxArray *
mxCreateNumericArray(mwSize ndim, const mwSize *dims, mxClassID cls,
                     mxComplexity c)
{
	int64_t d[3] = { 1, 1, 1 };
	for (int i = 0; i < ndim && i < 3; i++)
		d[i] = (int64_t) dims[i];
	mxArray *a = mx_ref_new((int64_t) cls, ndim < 1 ? 1 : ndim, d);
	if (!a) return NULL;
	int64_t k = mx_ref_numel(a);
	size_t es = (size_t) mx_ref_elem_size((int64_t) cls);
	a->pr = calloc(k > 0 ? (size_t) k : 1, es);
	if (c == mxCOMPLEX) {
		a->pi = calloc(k > 0 ? (size_t) k : 1, es);
		a->flags |= MXF_COMPLEX;
	}
	return a;
}

mxArray *
mxCreateString(const char *s)
{
	size_t n = s ? strlen(s) : 0;
	int64_t d[3] = { 1, (int64_t) n, 1 };
	mxArray *a = mx_ref_new(mxCHAR_CLASS, 2, d);
	if (!a) return NULL;
	a->pr = calloc(n > 0 ? n : 1, 1);
	if (n > 0) memcpy(a->pr, s, n);
	return a;
}

mxArray *
mxCreateCharArray(mwSize m, mwSize n)
{
	int64_t d[3] = { (int64_t) m, (int64_t) n, 1 };
	mxArray *a = mx_ref_new(mxCHAR_CLASS, 2, d);
	if (!a) return NULL;
	int64_t k = (int64_t) m * n;
	a->pr = calloc(k > 0 ? (size_t) k : 1, sizeof(mxChar));
	return a;
}

mxArray *
mxCreateCharMatrixFromStrings(mwSize m, const char **strs)
{
	size_t n = 0;
	for (mwSize i = 0; i < m; i++) {
		size_t l = strlen(strs[i]);
		if (l > n) n = l;
	}
	int64_t d[3] = { (int64_t) m, (int64_t) n, 1 };
	mxArray *a = mx_ref_new(mxCHAR_CLASS, 2, d);
	if (!a) return NULL;
	a->pr = calloc((size_t) m * n > 0 ? (size_t) m * n : 1, 1);
	char *pr = (char *) a->pr;
	for (mwSize i = 0; i < m; i++) {
		size_t l = strlen(strs[i]);
		memcpy(pr + (size_t) i * n, strs[i], l);
		for (size_t j = l; j < n; j++)
			pr[(size_t) i * n + j] = ' ';
	}
	return a;
}

mxArray *
mxCreateLogicalMatrix(mwSize m, mwSize n)
{
	int64_t d[3] = { (int64_t) m, (int64_t) n, 1 };
	mxArray *a = mx_ref_new(mxLOGICAL_CLASS, 2, d);
	if (!a) return NULL;
	int64_t k = (int64_t) m * n;
	a->pr = calloc(k > 0 ? (size_t) k : 1, sizeof(mxLogical));
	return a;
}

mxArray *
mxCreateLogicalScalar(mxLogical v)
{
	int64_t d[3] = { 1, 1, 1 };
	mxArray *a = mx_ref_new(mxLOGICAL_CLASS, 2, d);
	if (!a) return NULL;
	a->pr = calloc(1, sizeof(mxLogical));
	((mxLogical *) a->pr)[0] = v;
	return a;
}

mxArray *
mxCreateCellMatrix(mwSize m, mwSize n)
{
	int64_t d[3] = { (int64_t) m, (int64_t) n, 1 };
	mxArray *a = mx_ref_new(mxCELL_CLASS, 2, d);
	if (!a) return NULL;
	int64_t k = (int64_t) m * n;
	a->cells = calloc(k > 0 ? (size_t) k : 1, sizeof(mxArray *));
	return a;
}

mxArray *
mxCreateStructMatrix(mwSize m, mwSize n, int nfields,
                     const char **field_names)
{
	int64_t d[3] = { (int64_t) m, (int64_t) n, 1 };
	mxArray *a = mx_ref_new(mxSTRUCT_CLASS, 2, d);
	if (!a) return NULL;
	a->nfields = nfields;
	if (nfields > 0) {
		a->fieldnames = (char **) calloc((size_t) nfields,
		                                 sizeof(char *));
		for (int f = 0; f < nfields; f++)
			a->fieldnames[f] = strdup(field_names[f]);
	}
	int64_t k = (int64_t) m * n;
	a->cells = calloc(k * nfields > 0 ? (size_t) (k * nfields) : 1,
	                  sizeof(mxArray *));
	return a;
}

mxArray *
mxCreateSparse(mwSize m, mwSize n, mwSize nzmax, mxComplexity c)
{
	int64_t d[3] = { (int64_t) m, (int64_t) n, 1 };
	mxArray *a = mx_ref_new(mxDOUBLE_CLASS, 2, d);
	if (!a) return NULL;
	a->flags |= MXF_SPARSE;
	a->nzmax = (int64_t) nzmax;
	a->pr = calloc(nzmax > 0 ? (size_t) nzmax : 1, sizeof(double));
	a->ir = (mwIndex *) calloc(nzmax > 0 ? (size_t) nzmax : 1,
	                           sizeof(mwIndex));
	a->jc = (mwIndex *) calloc((size_t) n + 1, sizeof(mwIndex));
	if (c == mxCOMPLEX) {
		a->pi = calloc(nzmax > 0 ? (size_t) nzmax : 1, sizeof(double));
		a->flags |= MXF_COMPLEX;
	}
	return a;
}

/* ---------------------------------------------------------------- */
/* mxGet* (read)                                                     */
/* ---------------------------------------------------------------- */

double *
mxGetPr(const mxArray *a)
{
	return (double *) (a ? a->pr : NULL);
}

double *
mxGetPi(const mxArray *a)
{
	return (double *) (a ? a->pi : NULL);
}

void *
mxGetData(const mxArray *a)
{
	return a ? a->pr : NULL;
}

double *
mxGetDoubles(const mxArray *a)
{
	return (double *) (a ? a->pr : NULL);
}

double *
mxGetComplexDoubles(const mxArray *a)
{
	return (double *) (a ? a->pr : NULL);
}

double
mxGetScalar(const mxArray *a)
{
	if (!a || !a->pr) return 0.0;
	return ((double *) a->pr)[0];
}

mwSize
mxGetM(const mxArray *a)
{
	return a ? (mwSize) a->dims[0] : 0;
}

mwSize
mxGetN(const mxArray *a)
{
	return a ? (mwSize) a->dims[1] : 0;
}

mwSize
mxGetNumberOfElements(const mxArray *a)
{
	return a ? (mwSize) mx_ref_numel(a) : 0;
}

const mwSize *
mxGetDimensions(const mxArray *a)
{
	return a ? (const mwSize *) a->dims : NULL;
}

mwSize
mxGetNumberOfDimensions(const mxArray *a)
{
	return a ? (mwSize) a->rank : 0;
}

mxClassID
mxGetClassID(const mxArray *a)
{
	return a ? (mxClassID) a->class_id : mxUNKNOWN_CLASS;
}

const char *
mxGetClassName(const mxArray *a)
{
	static const char *names[] = {
		"unknown", "cell", "struct", "logical", "char", "function_handle",
		"double", "single", "int8", "uint8", "int16", "uint16",
		"int32", "uint32", "int64", "uint64", "", "object"
	};
	if (!a || a->class_id < 0 || a->class_id > 17)
		return "unknown";
	return names[a->class_id];
}

mwSize
mxGetElementSize(const mxArray *a)
{
	return a ? (mwSize) mx_ref_elem_size(a->class_id) : 0;
}

mxChar *
mxGetChars(const mxArray *a)
{
	return a ? (mxChar *) a->pr : NULL;
}

int
mxGetString(const mxArray *a, char *buf, mwSize buflen)
{
	if (!a || !a->pr || !buf || buflen < 1)
		return 1;
	if (a->class_id != mxCHAR_CLASS)
		return 1;
	const char *pr = (const char *) a->pr;
	int64_t n = mx_ref_numel(a);
	int64_t m = (int64_t) buflen - 1;
	if (n < m) m = n;
	for (int64_t i = 0; i < m; i++)
		buf[i] = pr[i];
	buf[m] = '\0';
	return 0;
}

char *
mxArrayToString(const mxArray *a)
{
	if (!a || !a->pr || a->class_id != mxCHAR_CLASS) {
		char *e = (char *) malloc(1);
		if (e) e[0] = '\0';
		return e;
	}
	int64_t m = a->dims[0], n = a->dims[1];
	const char *pr = (const char *) a->pr;
	int64_t total = m * n + m;   /* rows + m newlines (multi-row) */
	char *out = (char *) malloc((size_t) total + 1);
	if (!out) return NULL;
	int64_t p = 0;
	if (m <= 1) {
		memcpy(out, pr, (size_t) n);
		p = n;
	} else {
		for (int64_t i = 0; i < m; i++) {
			if (i > 0) out[p++] = '\n';
			memcpy(out + p, pr + (size_t) i * n, (size_t) n);
			p += n;
		}
	}
	out[p] = '\0';
	return out;
}

mwIndex *
mxGetIr(const mxArray *a)
{
	return a ? a->ir : NULL;
}

mwIndex *
mxGetJc(const mxArray *a)
{
	return a ? a->jc : NULL;
}

mwSize
mxGetNzmax(const mxArray *a)
{
	return a ? (mwSize) a->nzmax : 0;
}

mxArray *
mxGetCell(const mxArray *a, mwIndex idx)
{
	if (!a || a->class_id != mxCELL_CLASS || !a->cells)
		return NULL;
	return a->cells[idx];
}

mxArray *
mxGetField(const mxArray *a, mwIndex idx, const char *name)
{
	if (!a || a->class_id != mxSTRUCT_CLASS || !a->cells)
		return NULL;
	int64_t k = mx_ref_numel(a);
	if ((int64_t) idx >= k) return NULL;
	for (int f = 0; f < a->nfields; f++) {
		if (a->fieldnames[f] && strcmp(a->fieldnames[f], name) == 0)
			return a->cells[(int64_t) idx * a->nfields + f];
	}
	return NULL;
}

int
mxGetNumberOfFields(const mxArray *a)
{
	return a ? (int) a->nfields : 0;
}

const char *
mxGetFieldNameByNumber(const mxArray *a, int n)
{
	if (!a || n < 0 || n >= a->nfields)
		return NULL;
	return a->fieldnames[n];
}

int
mxGetFieldNumber(const mxArray *a, const char *name)
{
	if (!a || !name) return -1;
	for (int f = 0; f < a->nfields; f++) {
		if (a->fieldnames[f] && strcmp(a->fieldnames[f], name) == 0)
			return f;
	}
	return -1;
}

mwIndex
mxCalcSingleSubscript(const mxArray *a, mwSize nsubs, const mwIndex *subs)
{
	mwIndex idx = 0, mult = 1;
	for (mwSize i = 0; i < nsubs; i++) {
		mwIndex d = (i < (mwSize) a->rank) ? (mwIndex) a->dims[i] : 1;
		mwIndex s = subs[i] < d ? subs[i] : d - 1;
		idx += s * mult;
		mult *= d;
	}
	return idx;
}

/* ---------------------------------------------------------------- */
/* mxIs*                                                             */
/* ---------------------------------------------------------------- */

int mxIsDouble(const mxArray *a)  { return a && a->class_id == mxDOUBLE_CLASS; }
int mxIsSingle(const mxArray *a)  { return a && a->class_id == mxSINGLE_CLASS; }
int mxIsChar(const mxArray *a)    { return a && a->class_id == mxCHAR_CLASS; }
int mxIsCell(const mxArray *a)    { return a && a->class_id == mxCELL_CLASS; }
int mxIsStruct(const mxArray *a)  { return a && a->class_id == mxSTRUCT_CLASS; }
int mxIsLogical(const mxArray *a){ return a && a->class_id == mxLOGICAL_CLASS; }
int mxIsSparse(const mxArray *a)  { return a && (a->flags & MXF_SPARSE); }
int mxIsComplex(const mxArray *a){ return a && (a->flags & MXF_COMPLEX); }
int mxIsEmpty(const mxArray *a)   { return a && mx_ref_numel(a) == 0; }
int mxIsScalar(const mxArray *a)  { return a && mx_ref_numel(a) == 1; }
int mxIsNumeric(const mxArray *a) {
	return a && (a->class_id == mxDOUBLE_CLASS || a->class_id == mxSINGLE_CLASS
	             || a->class_id == mxINT8_CLASS || a->class_id == mxUINT8_CLASS
	             || a->class_id == mxINT16_CLASS || a->class_id == mxUINT16_CLASS
	             || a->class_id == mxINT32_CLASS || a->class_id == mxUINT32_CLASS
	             || a->class_id == mxINT64_CLASS || a->class_id == mxUINT64_CLASS);
}
int mxIsClass(const mxArray *a, const char *name) {
	return a && strcmp(mxGetClassName(a), name) == 0;
}
int mxIsInt32(const mxArray *a)   { return a && a->class_id == mxINT32_CLASS; }
int mxIsNaN(double d)  { return isnan(d); }
int mxIsInf(double d)  { return isinf(d); }
int mxIsFinite(double d)  { return isfinite(d); }
int mxIsLogicalScalar(const mxArray *a) {
	return a && a->class_id == mxLOGICAL_CLASS && mx_ref_numel(a) == 1;
}
int mxIsLogicalScalarTrue(const mxArray *a) {
	return mxIsLogicalScalar(a) && ((mxLogical *) a->pr)[0] != 0;
}

double mxGetEps(void) { return 2.2204460492503131e-16; }
double mxGetInf(void) { return INFINITY; }
double mxGetNaN(void) { return NAN; }

/* ---------------------------------------------------------------- */
/* mxSet* (write)                                                    */
/* ---------------------------------------------------------------- */

void
mxSetPr(mxArray *a, double *pr)
{
	if (a) a->pr = pr;
}

void
mxSetPi(mxArray *a, double *pi)
{
	if (a) a->pi = pi;
}

void
mxSetData(mxArray *a, void *p)
{
	if (a) a->pr = p;
}

void
mxSetIr(mxArray *a, mwIndex *ir)
{
	if (a) a->ir = ir;
}

void
mxSetJc(mxArray *a, mwIndex *jc)
{
	if (a) a->jc = jc;
}

void
mxSetCell(mxArray *a, mwIndex idx, mxArray *v)
{
	if (!a || a->class_id != mxCELL_CLASS || !a->cells)
		return;
	if (a->cells[idx])
		mxDestroyArray(a->cells[idx]);
	a->cells[idx] = v;
}

void
mxSetField(mxArray *a, mwIndex idx, const char *name, mxArray *v)
{
	if (!a || a->class_id != mxSTRUCT_CLASS || !a->cells)
		return;
	int f = mxGetFieldNumber(a, name);
	if (f < 0) return;
	mwIndex at = idx * (mwIndex) a->nfields + (mwIndex) f;
	if (a->cells[at])
		mxDestroyArray(a->cells[at]);
	a->cells[at] = v;
}

void
mxSetClassName(mxArray *a, const char *name)
{
	(void) a; (void) name;   /* objects unsupported on the reference track */
}

/* ---------------------------------------------------------------- */
/* mx* (lifecycle / misc)                                            */
/* ---------------------------------------------------------------- */

void *
mxMalloc(size_t n)
{
	return malloc(n);
}

void *
mxCalloc(size_t n, size_t sz)
{
	return calloc(n, sz);
}

void *
mxRealloc(void *p, size_t n)
{
	return realloc(p, n);
}

void
mxFree(void *p)
{
	free(p);
}

static void
mx_ref_deep_free(mxArray *a)
{
	if (!a) return;
	if (a->class_id == mxCELL_CLASS && a->cells) {
		int64_t k = mx_ref_numel(a);
		for (int64_t i = 0; i < k; i++)
			if (a->cells[i]) mx_ref_deep_free(a->cells[i]);
		free(a->cells);
	}
	if (a->class_id == mxSTRUCT_CLASS && a->cells) {
		int64_t k = mx_ref_numel(a);
		for (int64_t i = 0; i < k * a->nfields; i++)
			if (a->cells[i]) mx_ref_deep_free(a->cells[i]);
		free(a->cells);
		for (int f = 0; f < a->nfields; f++)
			free(a->fieldnames[f]);
		free(a->fieldnames);
	}
	free(a->pr);
	free(a->pi);
	free(a->ir);
	free(a->jc);
	free(a);
}

void
mxDestroyArray(mxArray *a)
{
	if (a) mx_ref_deep_free(a);
}

static mxArray *
mx_ref_deep_copy(const mxArray *a)
{
	if (!a) return NULL;
	int64_t d[3] = { a->dims[0], a->dims[1], a->dims[2] };
	mxArray *b = mx_ref_new(a->class_id, a->rank, d);
	b->flags = a->flags;
	b->nzmax = a->nzmax;
	int64_t k = mx_ref_numel(a);
	if (a->pr) {
		size_t es = (size_t) mx_ref_elem_size(a->class_id);
		size_t nb = (size_t) (a->class_id == mxDOUBLE_CLASS && a->nzmax > k
		                      ? a->nzmax : k);
		if (nb < 1) nb = 1;
		b->pr = malloc(nb * es);
		if (b->pr) memcpy(b->pr, a->pr, nb * es);
	}
	if (a->pi) {
		size_t es = (size_t) mx_ref_elem_size(a->class_id);
		size_t nb = (size_t) (a->nzmax > k ? a->nzmax : k);
		if (nb < 1) nb = 1;
		b->pi = malloc(nb * es);
		if (b->pi) memcpy(b->pi, a->pi, nb * es);
	}
	if (a->ir) {
		b->ir = (mwIndex *) malloc(((size_t) (a->nzmax > 0 ? a->nzmax : 1))
		                           * sizeof(mwIndex));
		if (b->ir)
			memcpy(b->ir, a->ir,
			       (size_t) (a->nzmax > 0 ? a->nzmax : 1) * sizeof(mwIndex));
	}
	if (a->jc) {
		int64_t ncols = a->dims[1];
		b->jc = (mwIndex *) malloc(((size_t) ncols + 1) * sizeof(mwIndex));
		if (b->jc)
			memcpy(b->jc, a->jc, ((size_t) ncols + 1) * sizeof(mwIndex));
	}
	if (a->cells) {
		int64_t nc = (a->class_id == mxSTRUCT_CLASS)
			? k * a->nfields : k;
		b->cells = (mxArray **) calloc(nc > 0 ? (size_t) nc : 1,
		                               sizeof(mxArray *));
		for (int64_t i = 0; i < nc; i++)
			b->cells[i] = mx_ref_deep_copy(a->cells[i]);
	}
	if (a->fieldnames) {
		b->fieldnames = (char **) calloc((size_t) a->nfields,
		                                 sizeof(char *));
		for (int f = 0; f < a->nfields; f++)
			b->fieldnames[f] = strdup(a->fieldnames[f]);
	}
	return b;
}

mxArray *
mxDuplicateArray(const mxArray *a)
{
	return mx_ref_deep_copy(a);
}

int
mxAddField(mxArray *a, const char *name)
{
	if (!a || a->class_id != mxSTRUCT_CLASS)
		return -1;
	if (mxGetFieldNumber(a, name) >= 0)
		return mxGetFieldNumber(a, name);
	int f = (int) a->nfields;
	int64_t k = mx_ref_numel(a);
	a->fieldnames = (char **) realloc(a->fieldnames,
	                                  (size_t) (f + 1) * sizeof(char *));
	a->fieldnames[f] = strdup(name);
	a->cells = (mxArray **) realloc(a->cells,
	                                (size_t) (k * (f + 1)) * sizeof(mxArray *));
	for (int64_t i = k * (f + 1) - 1; i >= k * f; i--)
		a->cells[i] = NULL;
	a->nfields = f + 1;
	return f;
}

void
mxRemoveField(mxArray *a, int n)
{
	(void) a; (void) n;   /* not used by the corpus */
}

void
mxAssert(int cond, const char *msg)
{
	if (!cond) {
		fprintf(stderr, "Assertion failed: %s\n", msg ? msg : "");
		exit(1);
	}
}

/* ---------------------------------------------------------------- */
/* mex*                                                              */
/* ---------------------------------------------------------------- */

int
mexPrintf(const char *fmt, ...)
{
	va_list ap;
	/* Route to stderr: the harness dumps plhs to stdout (its output file),
	   so mexPrintf text must not corrupt the protocol.  The return count
	   (what the corpus checks) is unaffected. */
	va_start(ap, fmt);
	int n = vfprintf(stderr, fmt, ap);
	va_end(ap);
	return n;
}

void
mexErrMsgIdAndTxt(const char *id, const char *fmt, ...)
{
	va_list ap;
	fprintf(stderr, "Error using %s (%s)\n", mx_ref_current_mex, id);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, "\n");
	exit(1);
}

void
mexWarnMsgIdAndTxt(const char *id, const char *fmt, ...)
{
	va_list ap;
	fprintf(stderr, "Warning: %s: ", id);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, "\n");
}

void
mexLock(void)
{
	mx_ref_locked = 1;
}

void
mexUnlock(void)
{
	mx_ref_locked = 0;
}

int
mexIsLocked(void)
{
	return mx_ref_locked;
}

void
mexMakeArrayPersistent(mxArray *a)
{
	(void) a;
}

void
mexMakeMemoryPersistent(void *p)
{
	(void) p;
}

const char *
mexFunctionName(void)
{
	return mx_ref_current_mex;
}

int
mexCallMATLAB(int nlhs, mxArray *plhs[], int nrhs, mxArray *prhs[],
              const char *name)
{
	(void) nlhs; (void) plhs; (void) nrhs; (void) prhs; (void) name;
	fprintf(stderr, "Error using %s: mexCallMATLAB is not available on "
	        "the gcc reference track (needs a MATLAB host)\n",
	        mx_ref_current_mex);
	exit(1);
	return -1;
}

int
mexEvalString(const char *cmd)
{
	(void) cmd;
	fprintf(stderr, "Error using %s: mexEvalString is not available on "
	        "the gcc reference track (needs a MATLAB host)\n",
	        mx_ref_current_mex);
	exit(1);
	return -1;
}

mxArray *
mexGetVariable(const char *ws, const char *name)
{
	(void) ws; (void) name;
	return NULL;
}

/* ---------------------------------------------------------------- */
/* Harness protocol                                                  */
/* ---------------------------------------------------------------- */

#define MX_REF_LINE_MAX (1 << 20)

static char mx_ref_line[MX_REF_LINE_MAX];
static const char *mx_ref_p;

static void
mx_ref_skipws(void)
{
	while (*mx_ref_p && *mx_ref_p != '\n'
	       && (*mx_ref_p == ' ' || *mx_ref_p == '\t'))
		mx_ref_p++;
}

static int
mx_ref_getnum(double *out)
{
	char *e;
	double v = strtod(mx_ref_p, &e);
	if (e == mx_ref_p) return 0;
	*out = v;
	mx_ref_p = e;
	return 1;
}

static int
mx_ref_getll(int64_t *out)
{
	char *e;
	long long v = strtoll(mx_ref_p, &e, 10);
	if (e == mx_ref_p) return 0;
	*out = (int64_t) v;
	mx_ref_p = e;
	return 1;
}

/* Advance one whitespace-delimited token; returns its length. */
static size_t
mx_ref_tok(void)
{
	mx_ref_skipws();
	const char *s = mx_ref_p;
	while (*mx_ref_p && *mx_ref_p != '\n'
	       && *mx_ref_p != ' ' && *mx_ref_p != '\t')
		mx_ref_p++;
	return (size_t) (mx_ref_p - s);
}

static int
mx_ref_tok_is(const char *tok)
{
	size_t len = strlen(tok);
	return strncmp(mx_ref_p, tok, len) == 0;
}

static mxArray *
mx_ref_load_spec(void)
{
	size_t tl = mx_ref_tok();
	(void) tl;
	const char *tok = mx_ref_p - tl;
	if (memcmp(tok, "D", 1) == 0 && tl == 1) {
		int64_t rank;
		if (!mx_ref_getll(&rank)) return NULL;
		int64_t d[3] = { 1, 1, 1 };
		for (int64_t i = 0; i < rank && i < 3; i++)
			mx_ref_getll(&d[i]);
		mxArray *a = mx_ref_new(mxDOUBLE_CLASS, rank < 1 ? 1 : rank, d);
		int64_t k = mx_ref_numel(a);
		a->pr = calloc(k > 0 ? (size_t) k : 1, sizeof(double));
		for (int64_t i = 0; i < k; i++) {
			double v;
			if (!mx_ref_getnum(&v)) { mxDestroyArray(a); return NULL; }
			((double *) a->pr)[i] = v;
		}
		return a;
	}
	if (memcmp(tok, "Z", 1) == 0 && tl == 1) {
		int64_t rank;
		if (!mx_ref_getll(&rank)) return NULL;
		int64_t d[3] = { 1, 1, 1 };
		for (int64_t i = 0; i < rank && i < 3; i++)
			mx_ref_getll(&d[i]);
		mxArray *a = mx_ref_new(mxDOUBLE_CLASS, rank < 1 ? 1 : rank, d);
		a->flags |= MXF_COMPLEX;
		int64_t k = mx_ref_numel(a);
		a->pr = calloc(k > 0 ? (size_t) k : 1, sizeof(double));
		a->pi = calloc(k > 0 ? (size_t) k : 1, sizeof(double));
		for (int64_t i = 0; i < k; i++) {
			double v;
			if (!mx_ref_getnum(&v)) { mxDestroyArray(a); return NULL; }
			((double *) a->pr)[i] = v;
		}
		for (int64_t i = 0; i < k; i++) {
			double v;
			if (!mx_ref_getnum(&v)) { mxDestroyArray(a); return NULL; }
			((double *) a->pi)[i] = v;
		}
		return a;
	}
	if (memcmp(tok, "C", 1) == 0 && tl == 1) {
		int64_t len;
		if (!mx_ref_getll(&len)) return NULL;
		mx_ref_skipws();
		if (len < 0 || len > (int64_t) MX_REF_LINE_MAX - 16)
			return NULL;
		mxArray *a = mx_ref_new(mxCHAR_CLASS, 2,
		                        (int64_t[]) { 1, len, 1 });
		a->pr = calloc(len > 0 ? (size_t) len : 1, 1);
		memcpy(a->pr, mx_ref_p, (size_t) len);
		mx_ref_p += len;
		return a;
	}
	if (memcmp(tok, "L", 1) == 0 && tl == 1) {
		int64_t rank;
		if (!mx_ref_getll(&rank)) return NULL;
		int64_t d[3] = { 1, 1, 1 };
		for (int64_t i = 0; i < rank && i < 3; i++)
			mx_ref_getll(&d[i]);
		mxArray *a = mx_ref_new(mxLOGICAL_CLASS, rank < 1 ? 1 : rank, d);
		int64_t k = mx_ref_numel(a);
		a->pr = calloc(k > 0 ? (size_t) k : 1, sizeof(mxLogical));
		for (int64_t i = 0; i < k; i++) {
			int64_t v;
			if (!mx_ref_getll(&v)) { mxDestroyArray(a); return NULL; }
			((mxLogical *) a->pr)[i] = (mxLogical) (v != 0);
		}
		return a;
	}
	if (memcmp(tok, "I", 1) == 0 && tl == 1) {
		int64_t rank;
		if (!mx_ref_getll(&rank)) return NULL;
		int64_t d[3] = { 1, 1, 1 };
		for (int64_t i = 0; i < rank && i < 3; i++)
			mx_ref_getll(&d[i]);
		mxArray *a = mx_ref_new(mxINT32_CLASS, rank < 1 ? 1 : rank, d);
		int64_t k = mx_ref_numel(a);
		a->pr = calloc(k > 0 ? (size_t) k : 1, sizeof(int32_t));
		for (int64_t i = 0; i < k; i++) {
			int64_t v;
			if (!mx_ref_getll(&v)) { mxDestroyArray(a); return NULL; }
			((int32_t *) a->pr)[i] = (int32_t) v;
		}
		return a;
	}
	if (memcmp(tok, "CE", 2) == 0 && tl == 2) {
		int64_t nelem;
		if (!mx_ref_getll(&nelem)) return NULL;
		mxArray *a = mx_ref_new(mxCELL_CLASS, 2,
		                        (int64_t[]) { 1, nelem, 1 });
		a->cells = calloc(nelem > 0 ? (size_t) nelem : 1,
		                  sizeof(mxArray *));
		for (int64_t i = 0; i < nelem; i++)
			a->cells[i] = mx_ref_load_spec();
		return a;
	}
	if (memcmp(tok, "ST", 2) == 0 && tl == 2) {
		int64_t nfields;
		if (!mx_ref_getll(&nfields)) return NULL;
		mxArray *a = mx_ref_new(mxSTRUCT_CLASS, 2,
		                        (int64_t[]) { 1, 1, 1 });
		a->nfields = nfields;
		a->fieldnames = (char **) calloc((size_t) nfields,
		                                 sizeof(char *));
		a->cells = (mxArray **) calloc((size_t) nfields,
		                               sizeof(mxArray *));
		for (int64_t f = 0; f < nfields; f++) {
			size_t tl2 = mx_ref_tok();
			char *nm = (char *) malloc(tl2 + 1);
			memcpy(nm, mx_ref_p - tl2, tl2);
			nm[tl2] = '\0';
			a->fieldnames[f] = nm;
		}
		for (int64_t f = 0; f < nfields; f++)
			a->cells[f] = mx_ref_load_spec();
		return a;
	}
	if (memcmp(tok, "SP", 2) == 0 && tl == 2) {
		int64_t m, n, nzmax;
		if (!mx_ref_getll(&m) || !mx_ref_getll(&n) || !mx_ref_getll(&nzmax))
			return NULL;
		mxArray *a = mx_ref_new(mxDOUBLE_CLASS, 2,
		                        (int64_t[]) { m, n, 1 });
		a->flags |= MXF_SPARSE;
		a->nzmax = nzmax;
		a->ir = (mwIndex *) calloc(nzmax > 0 ? (size_t) nzmax : 1,
		                           sizeof(mwIndex));
		a->jc = (mwIndex *) calloc((size_t) n + 1, sizeof(mwIndex));
		a->pr = calloc(nzmax > 0 ? (size_t) nzmax : 1, sizeof(double));
		for (int64_t i = 0; i < nzmax; i++) {
			int64_t v;
			if (!mx_ref_getll(&v)) { mxDestroyArray(a); return NULL; }
			a->ir[i] = (mwIndex) v;
		}
		for (int64_t i = 0; i <= n; i++) {
			int64_t v;
			if (!mx_ref_getll(&v)) { mxDestroyArray(a); return NULL; }
			a->jc[i] = (mwIndex) v;
		}
		for (int64_t i = 0; i < nzmax; i++) {
			double v;
			if (!mx_ref_getnum(&v)) { mxDestroyArray(a); return NULL; }
			((double *) a->pr)[i] = v;
		}
		return a;
	}
	return NULL;
}

/* Load the inputs: first line "N <nrhs>", then one spec line per input. */
int
__mx_load_inputs(mxArray *prhs[], int cap)
{
	int nrhs = 0;
	/* header line: N <count> */
	if (!fgets(mx_ref_line, sizeof mx_ref_line, stdin))
		return 0;
	mx_ref_p = mx_ref_line;
	{
		size_t htl = mx_ref_tok();
		if (htl == 1 && memcmp(mx_ref_line, "N", 1) == 0) {
			int64_t v;
			if (mx_ref_getll(&v)) nrhs = (int) v;
		} else {
			mx_ref_p = mx_ref_line;   /* no header: reparse as one input */
			nrhs = 1;
		}
	}
	if (nrhs > cap) nrhs = cap;
	for (int i = 0; i < nrhs; i++) {
		if (!fgets(mx_ref_line, sizeof mx_ref_line, stdin))
			break;
		mx_ref_p = mx_ref_line;
		prhs[i] = mx_ref_load_spec();
	}
	return nrhs;
}

static void
mx_ref_dump_spec(const mxArray *a)
{
	if (!a) { printf("E"); return; }
	switch (a->class_id) {
	case mxDOUBLE_CLASS:
		if (a->flags & MXF_SPARSE) {
			int64_t k = a->nzmax;
			int64_t n = a->dims[1];
			printf("SP %lld %lld %lld ", (long long) a->dims[0],
			       (long long) n, (long long) k);
			for (int64_t i = 0; i < k; i++)
				printf("%llu ", (unsigned long long) a->ir[i]);
			for (int64_t i = 0; i <= n; i++)
				printf("%llu ", (unsigned long long) a->jc[i]);
			for (int64_t i = 0; i < k; i++)
				printf("%.17g ", ((double *) a->pr)[i]);
			return;
		}
		if (a->flags & MXF_COMPLEX) {
			int64_t k = mx_ref_numel(a);
			printf("Z %lld %lld %lld ", (long long) a->rank,
			       (long long) a->dims[0], (long long) a->dims[1]);
			for (int64_t i = 0; i < k; i++)
				printf("%.17g ", ((double *) a->pr)[i]);
			for (int64_t i = 0; i < k; i++)
				printf("%.17g ", ((double *) a->pi)[i]);
			return;
		}
		{
			int64_t k = mx_ref_numel(a);
			printf("D %lld %lld %lld ", (long long) a->rank,
			       (long long) a->dims[0], (long long) a->dims[1]);
			for (int64_t i = 0; i < k; i++)
				printf("%.17g ", ((double *) a->pr)[i]);
		}
		return;
	case mxCHAR_CLASS: {
		int64_t k = mx_ref_numel(a);
		printf("C %lld ", (long long) k);
		fwrite(a->pr, 1, (size_t) k, stdout);
		return;
	}
	case mxINT32_CLASS: {
		int64_t k = mx_ref_numel(a);
		printf("I %lld %lld %lld ", (long long) a->rank,
		       (long long) a->dims[0], (long long) a->dims[1]);
		for (int64_t i = 0; i < k; i++)
			printf("%d ", (int) ((int32_t *) a->pr)[i]);
		return;
	}
	case mxLOGICAL_CLASS: {
		int64_t k = mx_ref_numel(a);
		printf("L %lld %lld %lld ", (long long) a->rank,
		       (long long) a->dims[0], (long long) a->dims[1]);
		for (int64_t i = 0; i < k; i++)
			printf("%d ", (int) ((mxLogical *) a->pr)[i]);
		return;
	}
	case mxCELL_CLASS: {
		int64_t k = mx_ref_numel(a);
		printf("CE %lld ", (long long) k);
		for (int64_t i = 0; i < k; i++)
			mx_ref_dump_spec(a->cells[i]);
		return;
	}
	case mxSTRUCT_CLASS: {
		int64_t k = mx_ref_numel(a);
		printf("ST %d ", (int) a->nfields);
		for (int f = 0; f < a->nfields; f++)
			printf("%s ", a->fieldnames[f]);
		for (int64_t i = 0; i < k; i++)
			for (int f = 0; f < a->nfields; f++)
				mx_ref_dump_spec(a->cells[i * a->nfields + f]);
		return;
	}
	default:
		printf("D 2 0 0 ");
		return;
	}
}

void
__mx_dump_outputs(mxArray *plhs[], int cap)
{
	for (int i = 0; i < cap; i++) {
		if (!plhs[i]) continue;
		mx_ref_dump_spec(plhs[i]);
		printf("\n");
	}
	fflush(stdout);
}

/* ------------------------------------------------------------------ *
 * MAT-file API (libmat) — gcc reference track.
 *
 * The reference track has no real filesystem bridge for .mat files, so
 * MATFile is a process-global VIRTUAL store keyed by filename: matOpen
 * looks up/creates the store, matPutVariable/matDeleteVariable mutate it,
 * matClose keeps it alive (the corpus roundtrips within one process: a
 * close followed by a reopen of the same name must see the variables).
 * The A/B gate compares the plhs VALUES the MEX returns, so the virtual
 * store must agree with the main-repo mat_api.c only on the API surface,
 * not on the on-disk bytes.
 * ------------------------------------------------------------------ */

typedef struct mx_ref_mat_var {
	char *name;
	mxArray *value;               /* owned deep copy */
	struct mx_ref_mat_var *next;
} mx_ref_mat_var;

typedef struct mx_ref_matfile {
	char *filename;
	char mode;
	mx_ref_mat_var *vars;
	int64_t cursor;               /* matGetNextVariable position */
	struct mx_ref_matfile *next;
} mx_ref_matfile;

typedef struct mx_ref_matfile MATFile;

static mx_ref_matfile *mx_ref_mat_files = NULL;
static int mx_ref_mat_quiet = 0;

static mx_ref_mat_var *
mx_ref_mat_find_var(MATFile *mf, const char *name)
{
	for (mx_ref_mat_var *v = mf->vars; v; v = v->next)
		if (strcmp(v->name, name) == 0) return v;
	return NULL;
}

static void
mx_ref_mat_free(MATFile *mf)
{
	mx_ref_mat_var *v = mf->vars;
	while (v) {
		mx_ref_mat_var *next = v->next;
		free(v->name);
		if (v->value) mxDestroyArray(v->value);
		free(v);
		v = next;
	}
	free(mf->filename);
	free(mf);
}

void
matSetQuietErrorsOn(int b)
{
	mx_ref_mat_quiet = b;
}

MATFile *
matOpen(const char *filename, const char *mode)
{
	if (!filename || !mode) return NULL;
	MATFile *mf = mx_ref_mat_files;
	while (mf && strcmp(mf->filename, filename) != 0)
		mf = mf->next;
	if (mf && mode[0] == 'w') {
		/* Write mode: a fresh store (the caller rewrites the file).
		   Read/update mode REUSES the store so a close + reopen
		   roundtrip within one process sees the variables. */
		mx_ref_mat_free(mf);
		if (mx_ref_mat_files == mf)
			mx_ref_mat_files = mf->next;
		else {
			MATFile *p = mx_ref_mat_files;
			while (p && p->next != mf) p = p->next;
			if (p) p->next = mf->next;
		}
		mf = NULL;
	}
	if (!mf) {
		mf = (MATFile *) calloc(1, sizeof(MATFile));
		mf->filename = strdup(filename);
		mf->next = mx_ref_mat_files;
		mx_ref_mat_files = mf;
	}
	mf->mode = mode[0];
	mf->cursor = 0;
	return mf;
}

int
matClose(MATFile *pMF)
{
	/* Virtual store: keep the variables alive for a later matOpen
	   in the same process (the corpus roundtrips after close). */
	(void) pMF;
	return 0;
}

FILE *
matGetfp(MATFile *pMF)
{
	(void) pMF;
	return NULL;
}

char **
matGetDir(MATFile *pMF, int *num)
{
	if (!pMF) return NULL;
	int n = 0;
	for (mx_ref_mat_var *v = pMF->vars; v; v = v->next) n++;
	if (num) *num = n;
	char **out = (char **) calloc((size_t) n + 1, sizeof(char *));
	int i = 0;
	for (mx_ref_mat_var *v = pMF->vars; v; v = v->next)
		out[i++] = strdup(v->name);
	out[n] = NULL;
	return out;
}

static mxArray *
mx_ref_mat_get(MATFile *pMF, const char *name)
{
	if (!pMF || !name) return NULL;
	mx_ref_mat_var *v = mx_ref_mat_find_var(pMF, name);
	return v ? mxDuplicateArray(v->value) : NULL;
}

mxArray *
matGetVariable(MATFile *pMF, const char *name)
{
	return mx_ref_mat_get(pMF, name);
}

mxArray *
matGetVariableInfo(MATFile *pMF, const char *name)
{
	return mx_ref_mat_get(pMF, name);
}

static mxArray *
mx_ref_mat_next(MATFile *pMF, const char **nameptr)
{
	/* Corpus use: called once, right after open, expecting the first
	   variable.  Track the cursor in the MATFile. */
	if (!pMF) return NULL;
	mx_ref_mat_var *v = pMF->vars;
	int64_t skip = pMF->cursor;
	for (int64_t i = 0; v && i < skip; i++) v = v->next;
	if (!v) return NULL;
	pMF->cursor = skip + 1;
	if (nameptr) *nameptr = v->name;
	return mxDuplicateArray(v->value);
}

mxArray *
matGetNextVariable(MATFile *pMF, const char **nameptr)
{
	return mx_ref_mat_next(pMF, nameptr);
}

mxArray *
matGetNextVariableInfo(MATFile *pMF, const char **nameptr)
{
	return mx_ref_mat_next(pMF, nameptr);
}

int
matPutVariable(MATFile *pMF, const char *name, const mxArray *pm)
{
	if (!pMF || !name || !pm) return 1;
	mx_ref_mat_var *v = mx_ref_mat_find_var(pMF, name);
	if (v) {
		mxDestroyArray(v->value);
		v->value = mxDuplicateArray(pm);
	} else {
		v = (mx_ref_mat_var *) calloc(1, sizeof(mx_ref_mat_var));
		v->name = strdup(name);
		v->value = mxDuplicateArray(pm);
		/* tail insert: file order = put order (the corpus expects the
		   first-put variable to be matGetNextVariable's first result) */
		if (!pMF->vars) {
			pMF->vars = v;
		} else {
			mx_ref_mat_var *t = pMF->vars;
			while (t->next) t = t->next;
			t->next = v;
		}
	}
	return 0;
}

int
matPutVariableAsGlobal(MATFile *pMF, const char *name, const mxArray *pm)
{
	return matPutVariable(pMF, name, pm);
}

int
matDeleteVariable(MATFile *pMF, const char *name)
{
	if (!pMF || !name) return 1;
	mx_ref_mat_var **pp = &pMF->vars;
	while (*pp) {
		if (strcmp((*pp)->name, name) == 0) {
			mx_ref_mat_var *dead = *pp;
			*pp = dead->next;
			free(dead->name);
			mxDestroyArray(dead->value);
			free(dead);
			return 0;
		}
		pp = &(*pp)->next;
	}
	return 1;
}

char *
matGetString(MATFile *pMF, const char *name)
{
	if (!pMF || !name) return NULL;
	mx_ref_mat_var *v = mx_ref_mat_find_var(pMF, name);
	if (!v || !v->value || v->value->class_id != mxCHAR_CLASS) return NULL;
	int64_t n = mx_ref_numel(v->value);
	char *out = (char *) malloc((size_t) n + 1);
	if (!out) return NULL;
	memcpy(out, v->value->pr, (size_t) n);
	out[n] = '\0';
	return out;
}

int
matPutString(MATFile *pMF, const char *name, const char *str)
{
	if (!pMF || !name || !str) return 1;
	mxArray *a = mxCreateString(str);
	int rc = matPutVariable(pMF, name, a);
	mxDestroyArray(a);
	return rc;
}

#endif /* MX_REF_C */
