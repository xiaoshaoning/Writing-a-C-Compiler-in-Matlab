/* mxdouble.c — mexFunction: y = x + 1, plus a size scalar in the 2nd
 * output.  Exercises mxCreateDoubleMatrix, mxGetPr, mxGetM/N,
 * mxGetNumberOfElements, mxCreateDoubleScalar, mxGetScalar, mxIsDouble,
 * mexErrMsgIdAndTxt.  (mex.h include is skipped by cc_int; the matlabcc
 * preamble provides the types/constants.) */
#include "mex.h"

void
mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    if (nrhs < 1 || !mxIsDouble(prhs[0]))
        mexErrMsgIdAndTxt("MXDOUBLE:badInput", "need a double matrix");
    mwSize m = mxGetM(prhs[0]);
    mwSize n = mxGetN(prhs[0]);
    plhs[0] = mxCreateDoubleMatrix(m, n, mxREAL);
    double *x = mxGetPr(prhs[0]);
    double *y = mxGetPr(plhs[0]);
    mwSize numel = mxGetNumberOfElements(prhs[0]);
    for (mwSize i = 0; i < numel; i++)
        y[i] = x[i] + 1;
    if (nlhs > 1)
        plhs[1] = mxCreateDoubleScalar((double) m * n);
}

/* ---- harness main (appended by the matlabcc track) ---- */
mxArray *__mex_prhs[4];
mxArray *__mex_plhs[4];

int main()
{
    int i;
    __mex_prhs[0] = mxCreateDoubleMatrix(2, 3, mxREAL);
    double *px = mxGetPr(__mex_prhs[0]);
    for (i = 0; i < 6; i++)
        px[i] = (double) (i + 1);

    mexFunction(2, __mex_plhs, 1, __mex_prhs);

    printf("%d %d\n", (int) mxGetM(__mex_plhs[0]), (int) mxGetN(__mex_plhs[0]));
    double *py = mxGetPr(__mex_plhs[0]);
    for (i = 0; i < 6; i++)
        printf("%g%c", py[i], (i == 5) ? '\n' : 32);
    printf("%d %g\n", (int) mxGetNumberOfElements(__mex_plhs[0]),
           mxGetScalar(__mex_plhs[1]));
    return 0;
}