/* mxscalar.c — mxGetScalar / mxCreateDoubleScalar round-trip.
 * mexFunction: y = 2 * s.  Harness feeds 21.5, expects 43.
 * Exercises: mxCreateDoubleScalar, mxGetScalar, mxIsNaN (negative path). */
#include "mex.h"

void
mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    double s = mxGetScalar(prhs[0]);
    if (mxIsNaN(s))
        mexErrMsgIdAndTxt("MXSCALAR:nan", "scalar is NaN");
    plhs[0] = mxCreateDoubleScalar(2.0 * s);
}

/* ---- harness ---- */
mxArray *__mex_prhs[4];
mxArray *__mex_plhs[4];

int main()
{
    __mex_prhs[0] = mxCreateDoubleScalar(21.5);
    mexFunction(1, __mex_plhs, 1, __mex_prhs);
    printf("%g\n", mxGetScalar(__mex_plhs[0]));
    return mxGetScalar(__mex_plhs[0]) == 43.0 ? 0 : 1;
}