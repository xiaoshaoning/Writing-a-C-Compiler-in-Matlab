/* mxchar.c — char round-trip: mxIsChar, mxCreateString, mxGetString,
 * mxArrayToString, strcmp, strcat.
 * mexFunction: "prefix:<input>" via strcat, then back via mxCreateString
 * of mxArrayToString.  Harness feeds "hi", expects "prefix:hi". */
#include "mex.h"

void
mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    if (nrhs < 1 || !mxIsChar(prhs[0]))
        mexErrMsgIdAndTxt("MXCHAR:notChar", "need a char input");
    char *s = mxArrayToString(prhs[0]);
    char out[128];
    strcpy(out, "prefix:");
    strcat(out, s);
    plhs[0] = mxCreateString(out);
    mxFree(s);
}

/* ---- harness ---- */
mxArray *__mex_prhs[4];
mxArray *__mex_plhs[4];

int main()
{
    char buf[128];
    int ok;
    __mex_prhs[0] = mxCreateString("hi");
    mexFunction(1, __mex_plhs, 1, __mex_prhs);

    printf("%d\n", (int) mxIsChar(__mex_plhs[0]));
    printf("%d\n", (int) mxGetM(__mex_plhs[0]));
    mxGetString(__mex_plhs[0], buf, sizeof(buf));
    printf("%s\n", buf);
    ok = (strcmp(buf, "prefix:hi") == 0);
    return ok ? 0 : 1;
}