/* mxint.c — INT32 data movement via mxCreateNumericMatrix + mxGetData.
 * mexFunction: y = x + 100 on int32 data.  Harness feeds [10 20 30],
 * expects class mxINT32_CLASS and values [110 120 130]. */
#include "mex.h"

void
mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    mwSize m = mxGetM(prhs[0]);
    mwSize n = mxGetN(prhs[0]);
    plhs[0] = mxCreateNumericMatrix(m, n, mxINT32_CLASS, mxREAL);
    int32_t *x = (int32_t *) mxGetData(prhs[0]);
    int32_t *y = (int32_t *) mxGetData(plhs[0]);
    mwSize numel = mxGetNumberOfElements(prhs[0]);
    for (mwSize i = 0; i < numel; i++)
        y[i] = x[i] + 100;
}

/* ---- harness ---- */
mxArray *__mex_prhs[4];
mxArray *__mex_plhs[4];

int main()
{
    int i, ok;
    __mex_prhs[0] = mxCreateNumericMatrix(1, 3, mxINT32_CLASS, mxREAL);
    int32_t *ix = (int32_t *) mxGetData(__mex_prhs[0]);
    ix[0] = 10; ix[1] = 20; ix[2] = 30;

    mexFunction(1, __mex_plhs, 1, __mex_prhs);

    printf("%d\n", (int) mxGetClassID(__mex_plhs[0]));
    printf("%d %d %d\n", (int) mxGetM(__mex_plhs[0]), (int) mxGetN(__mex_plhs[0]),
           (int) mxGetNumberOfElements(__mex_plhs[0]));
    int32_t *oy = (int32_t *) mxGetData(__mex_plhs[0]);
    ok = 1;
    for (i = 0; i < 3; i++) {
        printf("%d%c", oy[i], (i == 2) ? '\n' : 32);
        if (oy[i] != 110 + (int) (i * 10))
            ok = 0;
    }
    printf("ok=%d\n", ok);
    return ok ? 0 : 1;
}