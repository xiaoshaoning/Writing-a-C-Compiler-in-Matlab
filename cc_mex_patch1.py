# -*- coding: utf-8 -*-
# ME-2 part 1: cc_int — 'const' keyword, mx/mex libfns (libargt + libret),
# and a cc_preamble() that emits the mx declaration text for the matlabcc
# track (the corpus sources #include "mex.h", which cc_int skips).
BS = chr(92); t = BS + 't'
p = 'src/cc_int.m'
s = open(p, encoding='utf-8').read()

def rep(old, new, ctx, atleast=1):
    global s
    n = s.count(old)
    assert n >= atleast, (ctx, n)
    s = s.replace(old, new, 1)

# ---- 1) 'const' keyword (token 190); also 'register' (191) as a no-op ----
rep("""    elseif strcmp(id, 'double')
        token = 189;            % Double
    else""",
    """    elseif strcmp(id, 'double')
        token = 189;            % Double
    elseif strcmp(id, 'const')
        token = 190;            % Const (no-op qualifier)
    elseif strcmp(id, 'register')
        token = 191;            % Register (no-op qualifier)
    else""",
    "const kw")

# parse_basetype: skip leading qualifiers
rep("""global token idname stags
base = 0;
stdef = 0;
if token == 131             % int
    next();""",
    """global token idname stags
base = 0;
stdef = 0;
while token == 190 || token == 191   % const / register: no-ops
    next();
end
if token == 131             % int
    next();""",
    "basetype const")

# parse_struct_members: qualifiers on members
rep("""while token ~= 125          % '}'
    if token == 131         % int
        mbase = 0;
        next();""",
    """while token ~= 125          % '}'
    while token == 190 || token == 191
        next();
    end
    if token == 131         % int
        mbase = 0;
        next();""",
    "struct member const")

# ---- 2) mx/mex library tables (libfns + libargt + new libret) ----
rep("""fptypes = struct();   % user function -> vector of parameter type codes
libcalls = struct();  % 'name_nargs' -> 1 for every shim used (emitted)""",
    """% mx/mex API: every corpus call becomes a `__cc_<name>_<nargs>` shim the
% simulator implements against its in-memory mxArray ABI (see the MEX
% support plan, Phase C).  libargt = per-arg type codes (0 int, 6 double,
% 8 pointer); libret = the return type (8 pointer, 6 double, 0 int,
% 4 void) which drives the call-site etype and thus where the simulator
% must place the result (rax vs xmm0).
libfns.mxCreateDoubleMatrix = 'mxCreateDoubleMatrix';
libargt.mxCreateDoubleMatrix = [0 0 0];        libret.mxCreateDoubleMatrix = 8;
libfns.mxCreateDoubleScalar = 'mxCreateDoubleScalar';
libargt.mxCreateDoubleScalar = 6;              libret.mxCreateDoubleScalar = 8;
libfns.mxCreateNumericMatrix = 'mxCreateNumericMatrix';
libargt.mxCreateNumericMatrix = [0 0 0 0];     libret.mxCreateNumericMatrix = 8;
libfns.mxCreateString = 'mxCreateString';
libargt.mxCreateString = 8;                    libret.mxCreateString = 8;
libfns.mxCreateCharArray = 'mxCreateCharArray';
libargt.mxCreateCharArray = [0 0];             libret.mxCreateCharArray = 8;
libfns.mxGetPr = 'mxGetPr';   libargt.mxGetPr = 8;   libret.mxGetPr = 8;
libfns.mxGetPi = 'mxGetPi';   libargt.mxGetPi = 8;   libret.mxGetPi = 8;
libfns.mxGetData = 'mxGetData'; libargt.mxGetData = 8; libret.mxGetData = 8;
libfns.mxGetChars = 'mxGetChars'; libargt.mxGetChars = 8; libret.mxGetChars = 8;
libfns.mxGetM = 'mxGetM';     libargt.mxGetM = 8;   libret.mxGetM = 0;
libfns.mxGetN = 'mxGetN';     libargt.mxGetN = 8;   libret.mxGetN = 0;
libfns.mxGetNumberOfElements = 'mxGetNumberOfElements';
libargt.mxGetNumberOfElements = 8;             libret.mxGetNumberOfElements = 0;
libfns.mxGetScalar = 'mxGetScalar';
libargt.mxGetScalar = 8;                       libret.mxGetScalar = 6;
libfns.mxGetClassID = 'mxGetClassID';
libargt.mxGetClassID = 8;                      libret.mxGetClassID = 0;
libfns.mxGetClassName = 'mxGetClassName';
libargt.mxGetClassName = 8;                    libret.mxGetClassName = 8;
libfns.mxGetDimensions = 'mxGetDimensions';
libargt.mxGetDimensions = 8;                   libret.mxGetDimensions = 8;
libfns.mxGetElementSize = 'mxGetElementSize';
libargt.mxGetElementSize = 8;                  libret.mxGetElementSize = 0;
libfns.mxIsDouble = 'mxIsDouble';   libargt.mxIsDouble = 8;   libret.mxIsDouble = 0;
libfns.mxIsChar = 'mxIsChar';     libargt.mxIsChar = 8;     libret.mxIsChar = 0;
libfns.mxIsComplex = 'mxIsComplex'; libargt.mxIsComplex = 8; libret.mxIsComplex = 0;
libfns.mxIsNaN = 'mxIsNaN';       libargt.mxIsNaN = 8;      libret.mxIsNaN = 0;
libfns.mxIsInf = 'mxIsInf';       libargt.mxIsInf = 8;      libret.mxIsInf = 0;
libfns.mxIsEmpty = 'mxIsEmpty';   libargt.mxIsEmpty = 8;    libret.mxIsEmpty = 0;
libfns.mxIsLogical = 'mxIsLogical'; libargt.mxIsLogical = 8; libret.mxIsLogical = 0;
libfns.mxGetString = 'mxGetString';
libargt.mxGetString = [8 8 0];                   libret.mxGetString = 0;
libfns.mxArrayToString = 'mxArrayToString';
libargt.mxArrayToString = 8;                     libret.mxArrayToString = 8;
libfns.mxDuplicateArray = 'mxDuplicateArray';
libargt.mxDuplicateArray = 8;                    libret.mxDuplicateArray = 8;
libfns.mxDestroyArray = 'mxDestroyArray';
libargt.mxDestroyArray = 8;                      libret.mxDestroyArray = 0;
libfns.mxSetData = 'mxSetData';
libargt.mxSetData = [8 8];                       libret.mxSetData = 0;
libfns.mxAssert = 'mxAssert';
libargt.mxAssert = [0 8];                        libret.mxAssert = 0;
libfns.mexPrintf = 'mexPrintf';                  libret.mexPrintf = 0;
libfns.mexErrMsgIdAndTxt = 'mexErrMsgIdAndTxt';
libargt.mexErrMsgIdAndTxt = [8 8];               libret.mexErrMsgIdAndTxt = 0;
libfns.mexEvalString = 'mexEvalString';
libargt.mexEvalString = 8;                       libret.mexEvalString = 0;
% string.h / stdio.  sprintf is varargs (int/char* mixed) so no libargt.
libfns.strcmp = 'strcmp'; libargt.strcmp = [8 8]; libret.strcmp = 0;
libfns.strlen = 'strlen'; libargt.strlen = 8;    libret.strlen = 0;
libfns.strcpy = 'strcpy'; libargt.strcpy = [8 8]; libret.strcpy = 8;
libfns.memcpy = 'memcpy'; libargt.memcpy = [8 8 0]; libret.memcpy = 8;
libfns.strncmp = 'strncmp'; libargt.strncmp = [8 8 0]; libret.strncmp = 0;
libfns.malloc = 'malloc'; libargt.malloc = 0; libret.malloc = 8;
libfns.free = 'free'; libargt.free = 8; libret.free = 0;
fptypes = struct();   % user function -> vector of parameter type codes
libret = struct();    % fall back: default 0 (int)
libcalls = struct();  % 'name_nargs' -> 1 for every shim used (emitted)""",
    "mx tables")

# ---- 3) call site: honor libret for the etype after a libcall ----
rep("""        if isfield(libfns, name)
            % runtime-library call: go through the Win64-ABI shim
            libcalls.(sprintf('%s_%d', name, nargs)) = 1;
            em(sprintf('""" + t + """call""" + t + """__cc_%s_%d', name, nargs));
            if isfield(libargt, name)        % all-double math intrinsic:
                etype = 6;                   % result is a VALUE in %xmm0
            end
        else""",
    """        if isfield(libfns, name)
            % runtime-library call: go through the shim; the simulator
            % implements <name> (dispatches on the symbol, not the CRT)
            libcalls.(sprintf('%s_%d', name, nargs)) = 1;
            em(sprintf('""" + t + """call""" + t + """__cc_%s_%d', name, nargs));
            if isfield(libret, name)
                etype = libret.(name);   % 8 ptr, 6 double, 0 int, 4 void
                if etype == 4
                    etype = 0;
                end
            end
        else""",
    "libret call")
rep("""        if isfield(fret, name)
            etype = fret.(name);
        elseif ~(isfield(libfns, name) && isfield(libargt, name))
            etype = 0;
        end""",
    """        if isfield(fret, name)
            etype = fret.(name);
        elseif ~(isfield(libfns, name) && isfield(libret, name))
            etype = 0;
        end""",
    "libret etype")

# ---- 4) cc_mex_preamble(): the mx declaration text for the matlabcc track ----
if 'function cc_mex_preamble(' not in s:
    s += """

function txt = cc_mex_preamble()
% cc_mex_preamble — the mx/mex declaration block prepended to a MEX source
% for the matlabcc track.  The corpus files `#include "mex.h"`, which
% cc_int skips (preprocessor lines), so the types/constants/macros the
% source relies on are provided here directly instead (typedefs + enums;
% no function prototypes needed — every mx/mex call becomes a shim and
% cc_int's libargt/libret tables drive promotions and return types).
txt = [
    'typedef int mxArray;' 10 ...
    'typedef int mwSize;' 10 ...
    'typedef int mwIndex;' 10 ...
    'typedef int mxChar;' 10 ...
    'typedef int mxLogical;' 10 ...
    'typedef unsigned int mxComplexity;' 10 ...
    'enum { mxREAL = 0, mxCOMPLEX = 1 };' 10 ...
    'enum { mxUNKNOWN_CLASS = 0, mxCELL_CLASS = 1, mxSTRUCT_CLASS = 2,' 10 ...
    '       mxLOGICAL_CLASS = 3, mxCHAR_CLASS = 4, mxFUNCTION_CLASS = 5,' 10 ...
    '       mxDOUBLE_CLASS = 6, mxSINGLE_CLASS = 7,' 10 ...
    '       mxINT8_CLASS = 8, mxUINT8_CLASS = 9,' 10 ...
    '       mxINT16_CLASS = 10, mxUINT16_CLASS = 11,' 10 ...
    '       mxINT32_CLASS = 12, mxUINT32_CLASS = 13,' 10 ...
    '       mxINT64_CLASS = 14, mxUINT64_CLASS = 15,' 10 ...
    '       mxOBJECT_CLASS = 17 };' 10 ...
    'enum { mxNULL = -1 };' 10 ...
    ]
end
"""
    open(p, 'w', encoding='utf-8').write(s)
    print("cc_int ME-2 part 1 applied")