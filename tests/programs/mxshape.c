/* mxshape.c — mxGetM/N/NumberOfElements/ClassID encoded into one scalar:
 * result = m + 100*n + 1e4*numel + 1e6*class.  Harness feeds a 2x3
 * double, expects 2 + 300 + 60000 + 6000000 = 6060302. */
#include "mex.h"

void
mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    double r = mxGetM(prhs[0])
             + 100.0 * mxGetN(prhs[0])
             + 10000.0 * mxGetNumberOfElements(prhs[0])
             + 1000000.0 * mxGetClassID(prhs[0]);
    plhs[0] = mxCreateDoubleScalar(r);
}

/* ---- harness ---- */
mxArray *__mex_prhs[4];
mxArray *__mex_plhs[4];

int main()
{
    int i;
    __mex_prhs[0] = mxCreateDoubleMatrix(2, 3, mxREAL);
    double *px = mxGetPr(__mex_prhs[0]);
    for (i = 0; i < 6; i++)
        px[i] = (double) (i + 1);
    mexFunction(1, __mex_plhs, 1, __mex_prhs);
    printf("%g\n", mxGetScalar(__mex_plhs[0]));
    return mxGetScalar(__mex_plhs[0]) == 6060302.0 ? 0 : 1;
}