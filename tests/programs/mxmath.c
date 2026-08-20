/* mxmath.c — sin/sqrt over a prhs double vector.
 * mexFunction: y[i] = sin(x[i]) + sqrt(x[i]).
 * Harness feeds [0.5 1 4 0.25], prints the four results. */
#include <math.h>
#include "mex.h"

void
mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    mwSize numel = mxGetNumberOfElements(prhs[0]);
    double *x = mxGetPr(prhs[0]);
    plhs[0] = mxCreateDoubleMatrix(1, numel, mxREAL);
    double *y = mxGetPr(plhs[0]);
    for (mwSize i = 0; i < numel; i++)
        y[i] = sin(x[i]) + sqrt(x[i]);
}

/* ---- harness ---- */
mxArray *__mex_prhs[4];
mxArray *__mex_plhs[4];

int main()
{
    int i;
    __mex_prhs[0] = mxCreateDoubleMatrix(1, 4, mxREAL);
    double *px = mxGetPr(__mex_prhs[0]);
    px[0] = 0.5; px[1] = 1.0; px[2] = 4.0; px[3] = 0.25;
    mexFunction(1, __mex_plhs, 1, __mex_prhs);
    double *py = mxGetPr(__mex_plhs[0]);
    for (i = 0; i < 4; i++)
        printf("%.6f%c", py[i], (i == 3) ? '\n' : 32);
    return 0;
}