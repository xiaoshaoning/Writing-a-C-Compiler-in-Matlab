function cc_int(varargin)
% cc_int — x86-64 assembly compiler (Norasandqer "Writing a C Compiler").
%   Part 1: `return <int>;`
%   Part 2: unary operators — `return -42;`, `return ~42;`, `return !42;`,
%           unary plus, arbitrarily nested (`return -~!5;`).
%   Part 3: bitwise binary operators — `|`, `&`, `^`, `<<`, `>>` with C
%           precedence (| < ^ < & < shift), left-associative.
%   Part 4: logical operators — `||` and `&&` with C precedence
%           (|| < && < bitwise) and short-circuit jumps; results normalize
%           to 0/1.
%   Part 5: comparisons — `==`, `!=`, `<`, `>`, `<=`, `>=` (signed),
%           precedence equality < relational < shift (C: `a & b < c` is
%           `a & (b < c)`), results normalize to 0/1 via setcc.
%   Part 6: arithmetic — `+`, `-`, `*`, `/`, `%` with full C precedence
%           (relational < shift < additive < term < unary), parenthesised
%           expressions, integer division truncating toward zero, `%` with
%           the dividend's sign (cqto/idivq).
%   Part 7: statements and variables — `int x;`, `int x = 5;` (comma
%           lists), local stack frame (subq after the prologue, backpatched
%           size), expression statements, assignment (right-associative,
%           address-based so `y = x = 5` chains), locals as primaries.
%   Part 8: control flow — `if`/`else`, `while`, blocks, and `return`
%           anywhere (jumps to a .Lmain_ret epilogue label).
%   Part 9: functions — multiple `int f(int a, int b) { … }` definitions,
%           calls (args pushed left-to-right, `call`, `addq` cleanup),
%           per-function frames (params at positive %%rbp offsets, locals
%           negative), recursion, forward references, return in eax.
%   Part 10: `char` variables/params/globals (byte movzbl/movb, char
%           literals), global variables (.comm / .data, rip-relative
%           access, constant initializers), and compound assignment
%           (`+=`, `-=`, `*=`, `/=`, `%=`, `<<=`, `>>=`, `&=`, `|=`, `^=`).
%   Part 11: pointers and arrays — `int *p`, `int a[10]` (local/global/
%           param), `&` / `*`, `p[i]`, pointer arithmetic (scaled by the
%           element size), string literals. Plus: `++`/`--` (pre/post),
%           `?:` ternary, `for`/`do-while`, `break`/`continue`, and `//`
%           and `/* */` comments.
%   Part 12: structs — `struct Tag { int x; char c; … };` definitions,
%           struct variables/arrays/pointers (global and local), `.` and
%           `->` member access (nested structs), element-scaled pointer
%           arithmetic on struct pointers. Struct values evaluate to their
%           address (no load); params/returns are by-pointer only.
%   Types: 0=int, 1=char, 2=int*, 3=char*, 4=int**, … (base + 2*ptr depth;
%   only t==1 is a byte; a pointer's element size is 1 iff t==3). Struct
%   value types are 1000+2*stid (stid from stags), pointers +2 per level;
%   estruc flags a struct VALUE (address in rax, no load).
%
% Emits COFF assembly for MSYS2 binutils on Windows (see README for the
% gcc invocation). Pipeline: tokenizer (next) → recursive-descent parser
% (parse_program/parse_expr/…) → codegen → peephole_pass (a post-codegen
% optimizer in its own file: dead-code removal, constant folding,
% address-mode simplification and stack-traffic reduction — see
% docs/2026-08-16-compiler-optimization-plan.md).
%
%   cc_int('in.c', 'out.s')
%   gcc out.s -o out
%   .\out.exe  (cmd)  /  ./out  (bash) — exit code is the returned value

global src si token token_val token_dval token_isflt idname strtext out fname lbl lvars lvartype ...
       lvararr fbytes funcs fret called retlbl cfn globals gtype garr glist ...
       strs nstr etype ltype cret loopctx stags sdefs nstid estruc ...
       lvarstruct gstruct typedefs enums lvarstride gstride bstride glabels sret sretsize libfns libcalls ginit fptypes libargt libret

if nargin ~= 2 && nargin ~= 3
    error('USAGE: cc_int in.c out.s');
end

peephole_on = 1;
if nargin == 3 && strcmp(varargin{3}, 'nopeephole')
    peephole_on = 0;
end

source_file = varargin{1};
destination_file = varargin{2};

fid = fopen(source_file, 'r');
if fid < 0
    error(sprintf('could not open(%s)', source_file));
end
src = char(fread(fid, inf, 'uint8')');
fclose(fid);

[~, name, ext] = fileparts(source_file);
fname = [name, ext];

si = 1;
token = 0;
token_val = 0;
token_dval = 0;      % the double value of a float literal
token_isflt = 0;     % 1 when the current Num is a float (double) literal
strtext = [];   % last string literal as DOUBLE codes (the clone mangles
                % backslash-bearing char strings crossing globals)
lbl = 0;      % unique-label counter for short-circuit jumps
cfn = 0;      % function counter (.LFBn/.LFEn/.Lretn)
loopctx = {};   % stack of {break_label, continue_label} for break/continue
lvars = struct();    % local/param name -> frame offset (bytes)
lvartype = struct(); % local/param name -> type code (0 int, 1 char, 2 int* …)
lvararr = struct();  % local name -> 1 if an array (name decays to a pointer)
fbytes = 0;          % current function's frame bytes (locals only)
funcs = struct();    % defined function name -> param count
fret = struct();     % function name -> return type code (0/1)
frettype = struct(); % function name -> full return type code
fparams = struct();  % function name -> per-param sizes (arg copies)
called = struct();   % called function names (verified defined at the end)
retlbl = '';         % current function's return label
cret = 0;            % current function returns char
cvoid = 0;           % current function returns void
etype = 0;           % type code of the current expression
ltype = 0;           % type of the last parsed lvalue (store width)
globals = struct();  % defined global names
gtype = struct();    % global name -> type code
garr = struct();     % global name -> 1 if an array
glist = {};          % {name, type, init or []} for the .comm/.data output
ginit = {};          % {name, type, codes} non-constant global inits (startup)
strs = {};           % {label, text} string literals for the .data output
nstr = 0;            % string-literal counter
stags = struct();    % struct tag -> stid (struct value types = 1000+2*stid)
sdefs = {};          % stid -> {size, membermap}; membermap: name -> {off,type}
nstid = 0;           % next struct id
estruc = 0;          % 1 = current expression is a struct VALUE (address in
                     % rax, no load pending)
lvarstruct = struct();  % local name -> 1 if a direct struct value
lvararr = struct();     % local name -> 1 if an array (name decays to a ptr)
lvarstride = struct();  % local array name -> per-level byte strides
bstride = [];           % the current expression's remaining array strides
curarrsz = 0;           % the current expression's array total size (0 if not)
gstruct = struct();     % global name -> 1 if a direct struct value
garr = struct();        % global name -> 1 if an array
gstride = struct();     % global array name -> per-level byte strides
typedefs = struct();    % typedef name -> base type code
enums = struct();       % enum constant name -> value
glabels = struct();    % label name -> {defined, line index, pending jmps}
sret = 0;             % the current function returns a struct
sretsize = 0;         % its size (bytes)
sretbase = 0;         % the hidden slot pointer's rbp offset
% runtime library: name -> CRT symbol. Calls to these emit a Win64-ABI
% shim (`__cc_<name>_<nargs>`) in the generated assembly instead of a
% direct `call`, so our stack-arg convention adapts to RCX/RDX/R8/R9.
libfns = struct();
libfns.printf = 'printf';
libfns.malloc = 'malloc';
libfns.memset = 'memset';
libfns.memcmp = 'memcmp';
libfns.exit = 'exit';
libfns.open = '_open';
libfns.read = '_read';
libfns.close = '_close';
% math intrinsics (double).  The shim name is __cc_<name>_<nargs>; the
% simulator (x86sim) emulates them with MATLAB math.  libargt records the
% declared parameter types (6 = double) so call sites promote int args.
libfns.sin = 'sin';     libfns.cos = 'cos';    libfns.tan = 'tan';
libfns.asin = 'asin';   libfns.acos = 'acos';  libfns.atan = 'atan';
libfns.sinh = 'sinh';   libfns.cosh = 'cosh';  libfns.tanh = 'tanh';
libfns.exp = 'exp';     libfns.log = 'log';    libfns.log10 = 'log10';
libfns.sqrt = 'sqrt';   libfns.fabs = 'fabs';  libfns.floor = 'floor';
libfns.ceil = 'ceil';   libfns.trunc = 'trunc'; libfns.round = 'round';
libfns.cbrt = 'cbrt';
libfns.fmod = 'fmod';   libfns.pow = 'pow';    libfns.fmin = 'fmin';
libfns.fmax = 'fmax';   libfns.atan2 = 'atan2';
libargt = struct();
libargt.sin = 6; libargt.cos = 6; libargt.tan = 6;
libargt.asin = 6; libargt.acos = 6; libargt.atan = 6;
libargt.sinh = 6; libargt.cosh = 6; libargt.tanh = 6;
libargt.exp = 6; libargt.log = 6; libargt.log10 = 6;
libargt.sqrt = 6; libargt.fabs = 6; libargt.floor = 6;
libargt.ceil = 6; libargt.trunc = 6; libargt.round = 6;
libargt.cbrt = 6;
libargt.fmod = [6 6]; libargt.pow = [6 6];
libargt.fmin = [6 6]; libargt.fmax = [6 6]; libargt.atan2 = [6 6];
% mx/mex API: every corpus call becomes a `__cc_<name>_<nargs>` shim the
% simulator implements against its in-memory mxArray ABI (see the MEX
% support plan, Phase C).  libargt = per-arg type codes (0 int, 6 double,
% 8 pointer); libret = the return type (8 pointer, 6 double, 0 int,
% 4 void) which drives the call-site etype and thus where the simulator
% must place the result (rax vs xmm0).
libret = struct();    % mx/mex + math return types (8 ptr / 6 double / 0 int)
for lm = {'sin','cos','tan','asin','acos','atan','sinh','cosh','tanh', ...
          'exp','log','log10','sqrt','fabs','floor','ceil','trunc','round', ...
          'cbrt','fmod','pow','fmin','fmax','atan2'}
    libret.(lm{1}) = 6;
end
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
% interleaved integer accessors: every width returns the data address
for lw = {'mxGetInt8s','mxGetUint8s','mxGetInt16s','mxGetUint16s', ...
         'mxGetInt32s','mxGetUint32s','mxGetInt64s','mxGetUint64s'}
    libfns.(lw{1}) = lw{1};
    libargt.(lw{1}) = 8;
    libret.(lw{1}) = 8;
end
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
libfns.mxIsNaN = 'mxIsNaN';       libargt.mxIsNaN = 6;      libret.mxIsNaN = 0;
libfns.mxIsInf = 'mxIsInf';       libargt.mxIsInf = 6;      libret.mxIsInf = 0;
libfns.mxIsEmpty = 'mxIsEmpty';   libargt.mxIsEmpty = 8;    libret.mxIsEmpty = 0;
libfns.mxIsLogical = 'mxIsLogical'; libargt.mxIsLogical = 8; libret.mxIsLogical = 0;
% class predicates for the integer classes
libfns.mxIsInt8 = 'mxIsInt8';   libargt.mxIsInt8 = 8;   libret.mxIsInt8 = 0;
libfns.mxIsUint8 = 'mxIsUint8'; libargt.mxIsUint8 = 8; libret.mxIsUint8 = 0;
libfns.mxIsInt16 = 'mxIsInt16'; libargt.mxIsInt16 = 8; libret.mxIsInt16 = 0;
libfns.mxIsUint16 = 'mxIsUint16'; libargt.mxIsUint16 = 8; libret.mxIsUint16 = 0;
libfns.mxIsInt32 = 'mxIsInt32'; libargt.mxIsInt32 = 8; libret.mxIsInt32 = 0;
libfns.mxIsUint32 = 'mxIsUint32'; libargt.mxIsUint32 = 8; libret.mxIsUint32 = 0;
libfns.mxIsInt64 = 'mxIsInt64'; libargt.mxIsInt64 = 8; libret.mxIsInt64 = 0;
libfns.mxIsUint64 = 'mxIsUint64'; libargt.mxIsUint64 = 8; libret.mxIsUint64 = 0;
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
% cell arrays
libfns.mxIsCell = 'mxIsCell'; libargt.mxIsCell = 8; libret.mxIsCell = 0;
libfns.mxCreateCellMatrix = 'mxCreateCellMatrix';
libargt.mxCreateCellMatrix = [0 0];               libret.mxCreateCellMatrix = 8;
libfns.mxGetCell = 'mxGetCell';
libargt.mxGetCell = [8 0];                        libret.mxGetCell = 8;
libfns.mxSetCell = 'mxSetCell';
libargt.mxSetCell = [8 0 8];                      libret.mxSetCell = 0;
% struct arrays
libfns.mxIsStruct = 'mxIsStruct'; libargt.mxIsStruct = 8; libret.mxIsStruct = 0;
libfns.mxCreateStructMatrix = 'mxCreateStructMatrix';
libargt.mxCreateStructMatrix = [0 0 0 8];         libret.mxCreateStructMatrix = 8;
libfns.mxGetNumberOfFields = 'mxGetNumberOfFields';
libargt.mxGetNumberOfFields = 8;                  libret.mxGetNumberOfFields = 0;
libfns.mxGetFieldNumber = 'mxGetFieldNumber';
libargt.mxGetFieldNumber = [8 8];                 libret.mxGetFieldNumber = 0;
libfns.mxGetFieldNameByNumber = 'mxGetFieldNameByNumber';
libargt.mxGetFieldNameByNumber = [8 0];           libret.mxGetFieldNameByNumber = 8;
libfns.mxGetField = 'mxGetField';
libargt.mxGetField = [8 0 8];                     libret.mxGetField = 8;
libfns.mxGetFieldByNumber = 'mxGetFieldByNumber';
libargt.mxGetFieldByNumber = [8 0 0];             libret.mxGetFieldByNumber = 8;
libfns.mxSetField = 'mxSetField';
libargt.mxSetField = [8 0 8 8];                   libret.mxSetField = 0;
libfns.mxSetFieldByNumber = 'mxSetFieldByNumber';
libargt.mxSetFieldByNumber = [8 0 0 8];           libret.mxSetFieldByNumber = 0;
% sparse
libfns.mxIsSparse = 'mxIsSparse'; libargt.mxIsSparse = 8; libret.mxIsSparse = 0;
libfns.mxCreateSparse = 'mxCreateSparse';
libargt.mxCreateSparse = [0 0 0 0];               libret.mxCreateSparse = 8;
libfns.mxGetIr = 'mxGetIr';     libargt.mxGetIr = 8;     libret.mxGetIr = 8;
libfns.mxGetJc = 'mxGetJc';     libargt.mxGetJc = 8;     libret.mxGetJc = 8;
libfns.mxGetNzmax = 'mxGetNzmax'; libargt.mxGetNzmax = 8; libret.mxGetNzmax = 0;
libfns.mxSetIr = 'mxSetIr';     libargt.mxSetIr = [8 8]; libret.mxSetIr = 0;
libfns.mxSetJc = 'mxSetJc';     libargt.mxSetJc = [8 8]; libret.mxSetJc = 0;
% lifecycle
libfns.mexLock = 'mexLock';                       libret.mexLock = 0;
libfns.mexUnlock = 'mexUnlock';                   libret.mexUnlock = 0;
libfns.mexIsLocked = 'mexIsLocked';               libret.mexIsLocked = 0;
libfns.mexMakeArrayPersistent = 'mexMakeArrayPersistent';
libargt.mexMakeArrayPersistent = 8;               libret.mexMakeArrayPersistent = 0;
libfns.mexMakeMemoryPersistent = 'mexMakeMemoryPersistent';
libargt.mexMakeMemoryPersistent = 8;              libret.mexMakeMemoryPersistent = 0;
libfns.mexAtExit = 'mexAtExit';
libargt.mexAtExit = 8;                            libret.mexAtExit = 0;
% callbacks
libfns.mexCallMATLAB = 'mexCallMATLAB';
libargt.mexCallMATLAB = [0 8 0 8 8];              libret.mexCallMATLAB = 0;
libfns.mexCallMATLABWithTrap = 'mexCallMATLABWithTrap';
libargt.mexCallMATLABWithTrap = [0 8 0 8 8];      libret.mexCallMATLABWithTrap = 8;
libfns.mexEvalStringWithTrap = 'mexEvalStringWithTrap';
libargt.mexEvalStringWithTrap = 8;                libret.mexEvalStringWithTrap = 8;
libfns.mexGetVariable = 'mexGetVariable';
libargt.mexGetVariable = [8 8];                   libret.mexGetVariable = 8;
libfns.mexGetVariablePtr = 'mexGetVariablePtr';
libargt.mexGetVariablePtr = [8 8];                libret.mexGetVariablePtr = 8;
libfns.mexPutVariable = 'mexPutVariable';
libargt.mexPutVariable = [8 8 8];                 libret.mexPutVariable = 0;
% string.h / stdio.  sprintf is varargs (int/char* mixed) so no libargt.
libfns.strcmp = 'strcmp'; libargt.strcmp = [8 8]; libret.strcmp = 0;
libfns.strlen = 'strlen'; libargt.strlen = 8;    libret.strlen = 0;
libfns.strcpy = 'strcpy'; libargt.strcpy = [8 8]; libret.strcpy = 8;
libfns.memcpy = 'memcpy'; libargt.memcpy = [8 8 0]; libret.memcpy = 8;
libfns.strncmp = 'strncmp'; libargt.strncmp = [8 8 0]; libret.strncmp = 0;
libfns.malloc = 'malloc'; libargt.malloc = 0; libret.malloc = 8;
libfns.free = 'free'; libargt.free = 8; libret.free = 0;
libfns.mxFree = 'mxFree'; libargt.mxFree = 8; libret.mxFree = 0;
libfns.mxMalloc = 'mxMalloc'; libargt.mxMalloc = 0; libret.mxMalloc = 8;
libfns.mxCalloc = 'mxCalloc'; libargt.mxCalloc = [0 0]; libret.mxCalloc = 8;
libfns.strcat = 'strcat'; libargt.strcat = [8 8]; libret.strcat = 8;
fptypes = struct();   % user function -> vector of parameter type codes
libcalls = struct();  % 'name_nargs' -> 1 for every shim used (emitted)
out = {};       % emitted assembly lines (cell; tabs are literal in em)

next();
parse_program();
% the peephole optimizer is the dominant compile cost on the clone's
% slow string ops; the mex oracle path (mex_run) skips it via the
% 'nopeephole' flag — the corpus runs identically either way (the sim
% executes unoptimized code fine).
if peephole_on
    out = peephole_pass(out);
end

fid_output = fopen(destination_file, 'w+');
if fid_output < 0
    error(sprintf('could not open(%s)', destination_file));
end
fprintf(fid_output, '%s', cc_int_join(out));
fclose(fid_output);
end

function s = cc_int_join(lines)
% cc_int_join — join the emitted line cells into one output string.
s = '';
for k = 1:numel(lines)
    s = [s, lines{k}, char(10)];
end
end

% ---------------------------------------------------------------------------
% helpers
% ---------------------------------------------------------------------------

function fail(msg)
% fail — abort compilation with a message.
error(msg);
end

function idx = em(line)
% em — append one assembly line to the output cell. MATLAB strings do not
% process C escapes, so a literal backslash-t becomes a tab. Returns the
% cell index (used to backpatch the frame size).
global out
out{end+1} = strrep(line, '\t', char(9));
idx = numel(out);
end

function expect(tk)
% expect — consume the current token if it equals tk, else fail.
global token
if token == tk
    next();
else
    fail(sprintf('expected token %d, got %d', tk, token));
end
end

function next()
% next — tokenizer. Num=128, Return=130, Int=131, Char=134, Str=172, Id=150,
% Shl=140, Shr=141, Lan=142, Lor=143, Lt=144, Gt=145, Le=146, Ge=147,
% Eq=148, Ne=149, Assign=61 ('='), AddAssign=160 .. XorAssign=169, Inc=170,
% Dec=171, For=173, Do=174, Break=175, Continue=176; single-char
% operators/braces keep their ASCII code; 0 = EOF. Skips whitespace and
% `//`/`/* */` comments. Identifier text goes into idname; char literals
% ('A', '\n') become Num; string literals become Str (text in strtext).
global src si token token_val token_dval token_isflt idname strtext
while si <= numel(src)
    c = src(si);
    if c == ' ' || c == char(9) || c == char(10) || c == char(13)
        si = si + 1;
    elseif c == '/' && si + 1 <= numel(src) && src(si+1) == '/'
        while si <= numel(src) && src(si) ~= char(10) && src(si) ~= char(13)
            si = si + 1;
        end
    elseif c == '/' && si + 1 <= numel(src) && src(si+1) == '*'
        si = si + 2;
        while si + 1 <= numel(src) && ~(src(si) == '*' && src(si+1) == '/')
            si = si + 1;
        end
        si = si + 2;
    elseif c == 35                 % '#': skip the preprocessor line
        while si <= numel(src) && src(si) ~= char(10) && src(si) ~= char(13)
            si = si + 1;
        end
    else
        break;
    end
end
if si > numel(src)
    token = 0;                  % EOF
    return;
end
c = src(si);
if c >= '0' && c <= '9'
    isflt = 0;
    sstart = si;
    while si <= numel(src) && src(si) >= '0' && src(si) <= '9'
        si = si + 1;
    end
    if si <= numel(src) && src(si) == 46   % '.'
        isflt = 1;
        si = si + 1;
        while si <= numel(src) && src(si) >= '0' && src(si) <= '9'
            si = si + 1;
        end
    end
    if si <= numel(src) && (src(si) == 101 || src(si) == 69)  % e E
        p = si + 1;
        if p <= numel(src) && (src(p) == 43 || src(p) == 45)
            p = p + 1;
        end
        dig = 0;
        while p <= numel(src) && src(p) >= '0' && src(p) <= '9'
            p = p + 1;
            dig = 1;
        end
        if dig
            isflt = 1;
            si = p;
        end
    end
    if isflt
        d = str2double(char(src(sstart:si-1)));
        token = 128;                 % Num
        token_val = typecast(d, 'int64');   % the IEEE bit pattern
        token_dval = d;
        token_isflt = 1;
        return;
    end
    v = int64(0);
    for k = sstart:si-1
        v = v * int64(10) + int64(double(src(k)) - 48);
    end
    token = 128;                % Num
    token_val = v;
    token_isflt = 0;
    return;
elseif (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
    start = si;
    while si <= numel(src)
        d = src(si);
        if (d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z') || ...
           (d >= '0' && d <= '9') || d == '_'
            si = si + 1;
        else
            break;
        end
    end
    id = src(start:si-1);
    if strcmp(id, 'return')
        token = 130;            % Return
    elseif strcmp(id, 'int')
        token = 131;            % Int
    elseif strcmp(id, 'char')
        token = 134;            % Char
    elseif strcmp(id, 'if')
        token = 151;            % If
    elseif strcmp(id, 'while')
        token = 152;            % While
    elseif strcmp(id, 'else')
        token = 153;            % Else
    elseif strcmp(id, 'for')
        token = 173;            % For
    elseif strcmp(id, 'do')
        token = 174;            % Do
    elseif strcmp(id, 'break')
        token = 175;            % Break
    elseif strcmp(id, 'continue')
        token = 176;            % Continue
    elseif strcmp(id, 'struct')
        token = 178;            % Struct
    elseif strcmp(id, 'switch')
        token = 182;            % Switch
    elseif strcmp(id, 'case')
        token = 180;            % Case
    elseif strcmp(id, 'default')
        token = 181;            % Default
    elseif strcmp(id, 'sizeof')
        token = 183;            % Sizeof
    elseif strcmp(id, 'typedef')
        token = 184;            % Typedef
    elseif strcmp(id, 'enum')
        token = 185;            % Enum
    elseif strcmp(id, 'goto')
        token = 186;            % Goto
    elseif strcmp(id, 'void')
        token = 187;            % Void
    elseif strcmp(id, 'unsigned')
        token = 188;            % Unsigned
    elseif strcmp(id, 'double')
        token = 189;            % Double
    elseif strcmp(id, 'const')
        token = 190;            % Const (no-op qualifier)
    elseif strcmp(id, 'register')
        token = 191;            % Register (no-op qualifier)
    elseif strcmp(id, 'static')
        token = 192;            % Static (no-op qualifier)
    elseif strcmp(id, 'short')
        token = 193;            % Short: the 2-byte integer base (7)
    elseif strcmp(id, 'word')
        token = 194;            % Word: the 4-byte integer base (9); the
                                % oracle keeps int as the 64-bit base
    elseif strcmp(id, 'long')
        token = 195;            % Long: 8-byte (same base as int, 0)
    else
        token = 150;            % Id (incl. 'main'); text in idname
        idname = id;
    end
    return;
elseif c == 34                  % '"': string literal
    si = si + 1;
    strtext = [];
    while si <= numel(src)
        v = src(si);
        if v == 34              % closing quote
            break;
        end
        si = si + 1;
        if v == 92              % backslash escape
            if si <= numel(src)
                v = src(si);
                si = si + 1;
                if v == 110
                    v = char(10);
                end
            end
        end
        strtext = [strtext, double(v)];
    end
    if si > numel(src)
        fail('unterminated string literal');
    end
    si = si + 1;                % closing quote
    token = 172;                % Str
    return;
elseif c == 39                  % '\'': char literal
    si = si + 1;
    if si > numel(src)
        fail('unterminated char literal');
    end
    v = double(src(si));
    si = si + 1;
    if v == 92 && si <= numel(src)   % backslash escape
        v = double(src(si));
        si = si + 1;
        if v == 110
            v = 10;             % '\n'
        end
    end
    if si > numel(src) || double(src(si)) ~= 39
        fail('unterminated char literal');
    end
    si = si + 1;
    token = 128;                % Num
    token_val = int64(v);
    token_isflt = 0;
    return;
elseif c == '='
    si = si + 1;
    if si <= numel(src) && src(si) == '='
        si = si + 1;
        token = 148;            % Eq
    else
        token = 61;             % Assign ('=')
    end
    return;
elseif c == '!'
    si = si + 1;
    if si <= numel(src) && src(si) == '='
        si = si + 1;
        token = 149;            % Ne
    else
        token = 33;             % '!' (logical not)
    end
    return;
elseif c == '<'
    si = si + 1;
    if si <= numel(src) && src(si) == '='
        si = si + 1;
        token = 146;            % Le
    elseif si <= numel(src) && src(si) == '<'
        si = si + 1;
        if si <= numel(src) && src(si) == '='
            si = si + 1;
            token = 165;        % ShlAssign
        else
            token = 140;        % Shl
        end
    else
        token = 144;            % Lt
    end
    return;
elseif c == '>'
    si = si + 1;
    if si <= numel(src) && src(si) == '='
        si = si + 1;
        token = 147;            % Ge
    elseif si <= numel(src) && src(si) == '>'
        si = si + 1;
        if si <= numel(src) && src(si) == '='
            si = si + 1;
            token = 166;        % ShrAssign
        else
            token = 141;        % Shr
        end
    else
        token = 145;            % Gt
    end
    return;
elseif c == '&'
    si = si + 1;
    if si <= numel(src) && src(si) == '&'
        si = si + 1;
        token = 142;            % Lan
    elseif si <= numel(src) && src(si) == '='
        si = si + 1;
        token = 167;            % AndAssign
    else
        token = 38;             % '&'
    end
    return;
elseif c == '|'
    si = si + 1;
    if si <= numel(src) && src(si) == '|'
        si = si + 1;
        token = 143;            % Lor
    elseif si <= numel(src) && src(si) == '='
        si = si + 1;
        token = 168;            % OrAssign
    else
        token = 124;            % '|'
    end
    return;
elseif c == '+' || c == '-' || c == '*' || c == '/' || c == '%' || c == '^'
    si = si + 1;
    if si <= numel(src) && src(si) == '='
        si = si + 1;
        if c == '+'
            token = 160;        % AddAssign
        elseif c == '-'
            token = 161;        % SubAssign
        elseif c == '*'
            token = 162;        % MulAssign
        elseif c == '/'
            token = 163;        % DivAssign
        elseif c == '%'
            token = 164;        % ModAssign
        else
            token = 169;        % XorAssign
        end
    elseif c == '-' && si <= numel(src) && src(si) == '>'
        si = si + 1;
        token = 179;            % Arrow ('->')
    elseif c == '+' && si <= numel(src) && src(si) == '+'
        si = si + 1;
        token = 170;            % Inc
    elseif c == '-' && si <= numel(src) && src(si) == '-'
        si = si + 1;
        token = 171;            % Dec
    else
        token = double(c);
    end
    return;
else
    token = double(c);
    si = si + 1;
    return;
end
end

function parse_program()
% parse_program — file headers, then every top-level declaration/function;
% verify at the end that every called function and `main` were defined, and
% emit the global data section.
global token out fname funcs called glist libfns
em(sprintf('\t.file\t"%s"', fname));
em('\t.text');
while token ~= 0
    parse_decl_or_func();
end
names = fieldnames(called);
for k = 1:numel(names)
    if ~isfield(funcs, names{k}) && ~isfield(libfns, names{k})
        fail(sprintf('call to undefined function %s', names{k}));
    end
    if isfield(funcs, names{k})
        bad = find(called.(names{k}) ~= funcs.(names{k}), 1);
        if ~isempty(bad)
            fail(sprintf('function %s called with %d args, takes %d', ...
                names{k}, called.(names{k})(bad), funcs.(names{k})));
        end
    end
end
if ~isfield(funcs, 'main')
    fail('no main function');
end
emit_globals();
emit_libshims();
end

function emit_libshims()
% emit_libshims — Win64-ABI adapters for every runtime-library call used.
% Each `__cc_<name>_<nargs>` receives our stack-arg convention (arg1 at
% 16(%rbp)) and re-packs it into RCX/RDX/R8/R9 plus the 32-byte shadow
% space, aligns rsp to 16, zeroes AL (varargs), and calls the CRT symbol.
global out libcalls libfns
em('\t.text');
ck = fieldnames(libcalls);
for ci = 1:numel(ck)
    key = ck{ci};
    us = strfind(key, '_');
    nm = key(1:us(end)-1);
    na = str2num(key(us(end)+1:end));
    crt = libfns.(nm);
    em(sprintf('__cc_%s:', key));
    em('\tpushq\t%rbp');
    em('\tmovq\t%rsp, %rbp');
    em('\tandq\t$-16, %rsp');      % align regardless of the caller
    alloc = 32 + 8 * max(0, na - 4);
    alloc = 16 * ceil(alloc / 16);
    em(sprintf('\tsubq\t$%d, %%rsp', alloc));
    % our convention: arg1 was pushed first (deepest), so arg_k sits at
    % 16+8*(na-k)(%rbp)
    em(sprintf('\tmovq\t%d(%%rbp), %%rcx', 16 + 8 * (na - 1)));
    if na >= 2
        em(sprintf('\tmovq\t%d(%%rbp), %%rdx', 16 + 8 * (na - 2)));
    end
    if na >= 3
        em(sprintf('\tmovq\t%d(%%rbp), %%r8', 16 + 8 * (na - 3)));
    end
    if na >= 4
        em(sprintf('\tmovq\t%d(%%rbp), %%r9', 16 + 8 * (na - 4)));
    end
    for kk = 5:na
        % the kk-th arg at 16+8*(na-kk)(%rbp) -> the (kk-4)-th stack slot
        em(sprintf('\tmovq\t%d(%%rbp), %%r10', 16 + 8 * (na - kk)));
        em(sprintf('\tmovq\t%%r10, %d(%%rsp)', 32 + 8 * (kk - 5)));
    end
    em('\txorl\t%eax, %eax');     % no vector args for varargs
    em(sprintf('\tcall\t%s', crt));
    em('\tmovq\t%rbp, %rsp');
    em('\tpopq\t%rbp');
    em('\tret');
end
end

function parse_decl_or_func()
% type ('*')* name — '(' means a function definition, otherwise globals;
% a struct type definition (`struct Tag { … };`) registers the type;
% `typedef` registers a type alias; `enum { … }` registers constants.
global token idname typedefs enums
if token == 184         % typedef
    next();
    [base, stdef] = parse_basetype();
    if isa(stdef, 'cell')
        fail('struct definitions are not allowed in typedefs');
    end
    if token ~= 150
        fail('expected a typedef name');
    end
    typedefs.(idname) = base;
    next();
    expect(59);
    return;
end
if token == 185         % enum
    parse_enum();
    return;
end
[base, stdef] = parse_basetype();
if isa(stdef, 'cell')
    % a struct type definition: register the tag, then either the ';'
    % or a variable list of the new type (`struct Q { … } q;`)
    base = 1000 + 2 * register_struct(stdef{1}, stdef{2});
    if token == 59
        next();
        return;
    end
    depth = 0;
    while token == 42       % '*'
        depth = depth + 1;
        next();
    end
    if token ~= 150
        fail('expected a name');
    end
    name = idname;
    next();
    parse_globals(name, base, depth, 0);
    return;
end
depth = 0;
while token == 42           % '*'
    depth = depth + 1;
    next();
end
if token == 40              % '(': function pointer `(*name)(params)`
    next();
    if token ~= 42
        fail('expected * for a function pointer');
    end
    next();
    if token ~= 150
        fail('expected a function pointer name');
    end
    name = idname;
    next();
    expect(41);
    skip_prototype();       % (params): parsed and discarded
    parse_globals(name, base, depth, 1);   % fptrflag = 1 (rettype = base+2*depth)
    return;
end
if token ~= 150
    fail('expected a name');
end
name = idname;
next();
if token == 40              % '(': function (return type = base+2*depth)
    parse_function_tail(name, base == 1, base + 2 * depth);
else
    parse_globals(name, base, depth, 0);
end
end

function v = eval_const()
% eval_const — a compile-time constant expression: a number, a previously
% defined enum constant, a parenthesised expression, unary +/-, or binary
% + - * / % (used for enum values and array sizes).
global token token_val idname enums
if token == 128             % number
    v = double(token_val);
    next();
elseif token == 45          % unary -
    next();
    v = -eval_const();
elseif token == 43          % unary +
    next();
    v = eval_const();
elseif token == 40
    next();
    v = eval_const();
    expect(41);
elseif token == 150 && isfield(enums, idname)
    v = enums.(idname);
    next();
else
    fail('expected a constant expression');
end
while token == 43 || token == 45 || token == 42 || token == 47 || token == 37
    op = token;
    next();
    r = eval_const();
    if op == 43
        v = v + r;
    elseif op == 45
        v = v - r;
    elseif op == 42
        v = v * r;
    elseif op == 47
        v = fix(v / r);
    else                        % %
        v = v - fix(v / r) * r;
    end
end
end

function parse_enum()
% enum [tag] { A, B = n, … } ';' — register the constants (values start at
% 0 and increment, or follow explicit '=' expressions).
global token idname enums
next();                     % 'enum'
if token == 150             % optional tag
    next();
end
if token ~= 123
    fail('expected { after enum');
end
next();
i = 0;
while token ~= 125
    if token ~= 150
        fail('expected an enum identifier');
    end
    nm = idname;
    next();
    if token == 61          % '='
        next();
        i = eval_const();
    end
    enums.(nm) = i;
    i = i + 1;
    if token == 44
        next();
    end
end
next();                     % '}'
expect(59);                 % ';'
end

function [base, stdef] = parse_basetype()
% parse_basetype — parse int/char/struct tag; returns the base type code
% (0 int, 1 char, 1000+2*stid struct) and, for a struct type DEFINITION at
% file scope, a cell {tag, members} for the caller to register.
global token idname stags enums
base = 0;
stdef = 0;
while token == 190 || token == 191 || token == 192   % const / register / static: no-ops
    next();
end
if token == 131             % int
    next();
elseif token == 134         % char
    base = 1;
    next();
elseif token == 187         % void (only valid as a return type or (void))
    base = 4;
    next();
elseif token == 188         % unsigned (int): a 64-bit unsigned type
    base = 5;
    next();
    if token == 131         % 'unsigned int'
        next();
    end
elseif token == 189         % double
    base = 6;
    next();
elseif token == 193         % short: 2-byte integer base
    base = 7;
    next();
    if token == 131         % 'short int'
        next();
    end
elseif token == 194         % word: 4-byte integer base
    base = 9;
    next();
elseif token == 195         % long: 8-byte integer base (same as int)
    base = 0;
    next();
    if token == 131 || token == 193 || token == 194   % 'long int/short/word'
        next();
    end
elseif token == 178         % struct
    next();
    if token ~= 150
        fail('expected a struct tag');
    end
    tag = idname;
    next();
    if token == 123         % '{': type definition
        next();             % consume '{'
        stdef = {tag, parse_struct_members()};
    else
        if ~isfield(stags, tag)
            fail(sprintf('unknown struct %s', tag));
        end
        base = 1000 + 2 * stags.(tag);
    end
elseif token == 150 && isfield(typedefs, idname)
    base = typedefs.(idname);
    next();
elseif token == 185         % enum: `typedef enum { … } mxClassID;` —
    % register the constants, the type itself is an int (class ids)
    base = 0;
    next();
    if token == 150         % optional tag
        next();
    end
    if token ~= 123
        fail('expected { after enum');
    end
    next();
    i = 0;
    while token ~= 125 && token ~= 0
        if token ~= 150
            fail('expected an enum identifier');
        end
        enm = idname;
        next();
        if token == 61      % '='
            next();
            i = eval_const();
        end
        enums.(enm) = i;
        i = i + 1;
        if token == 44
            next();
        end
    end
    next();                 % '}'
else
    fail('expected a type');
end
end

function def = parse_struct_members()
% members := (type ('*')* name (('[' size ']')? …) ';')* '}' — returns
% {size, membermap, names}; membermap maps member name -> {offset, type};
% names lists the members in declaration order (for initializers).
global token idname stags
membermap = struct();
mnames = {};
off = 0;
while token ~= 125          % '}'
    while token == 190 || token == 191 || token == 192
        next();
    end
    if token == 131         % int
        mbase = 0;
        next();
    elseif token == 134     % char
        mbase = 1;
        next();
    elseif token == 189     % double
        mbase = 6;
        next();
    elseif token == 178     % struct
        next();
        if token ~= 150
            fail('expected a struct tag');
        end
        tag = idname;
        next();
        if ~isfield(stags, tag)
            fail(sprintf('unknown struct %s', tag));
        end
        mbase = 1000 + 2 * stags.(tag);
    else
        fail('expected a struct member type');
    end
    depth = 0;
    while token == 42       % '*'
        depth = depth + 1;
        next();
    end
    if token ~= 150
        fail('expected a member name');
    end
    name = idname;
    next();
    mt = mbase + 2 * depth;
    asz = 1;
    if token == 91          % '[': member array
        next();
        if token ~= 128
            fail('expected a constant array size');
        end
        asz = double(token_val);
        next();
        expect(93);
        if asz < 0
            fail('bad array size');
        end
    end
    if mt == 1
        st = 1;
    elseif mbase >= 1000 && depth == 0
        st = ssize_of(mbase);
    else
        st = 8;
    end
    nbytes = st * asz;
    if mt ~= 1
        off = off + mod(-off, 8);   % 8-align non-char members
    end
    membermap.(name) = {off, mt};
    mnames{end+1} = name;
    off = off + nbytes;
    expect(59);             % ';'
end
next();                     % consume '}'
% C allows trailing padding; 8-align the total size
sz = off + mod(-off, 8);
def = {sz, membermap, mnames};
end

function sid = register_struct(tag, def)
% register_struct — assign a stid to a struct type definition.
global stags sdefs nstid
if isfield(stags, tag)
    fail(sprintf('duplicate struct %s', tag));
end
nstid = nstid + 1;
stags.(tag) = nstid;
sdefs{nstid} = def;
sid = nstid;
end

function sz = ssize_of(t)
% ssize_of — byte size of a struct VALUE type (1000+2*stid).
global sdefs
stid = (t - 1000) / 2;
sz = sdefs{stid}{1};
end

function m = member_lookup(t, name)
% member_lookup — {offset, type} of member `name` in struct VALUE type t.
global sdefs
stid = (t - 1000) / 2;
mm = sdefs{stid}{2};
if isfield(mm, name)
    m = mm.(name);
else
    fail(sprintf('no member %s', name));
end
end

function sz = elem_size(t)
% elem_size — byte size per element for pointer arithmetic/indexing on
% type t: 1 for char*, 2/4 for the 2-/4-byte integer pointer types, the
% struct size for struct-related, else 8.
if t == 3
    sz = 1;
elseif t == 9              % base 7 *: 2-byte elements
    sz = 2;
elseif t == 11             % base 9 *: 4-byte elements
    sz = 4;
elseif t >= 1000 && t < 1002
    sz = ssize_of(t);
elseif t >= 1002
    sz = ssize_of(t - 2);
else
    sz = 8;
end
end

function s = cstride_of(dims, elem)
% array_strides — per-level byte strides: s(k) = elem * prod(dims(k+1:end));
% for int[2][3] (elem 8): s = [24 8] — a[i] advances 24 bytes, a[i][j] 8.
n = numel(dims);
s = zeros(1, n);
acc = elem;
for k = n:-1:1
    s(k) = acc;
    acc = acc * dims(k);
end
end

function vals = parse_arr_init(dims, lvl)
% parse_arr_init — a constant array initializer: {c1, c2, …} or a string
% literal. Nested braces fill sub-arrays (row-major alignment, C 6.7.9):
% {{1,2},{3}} on int[2][3] gives [1 2 0 3 0 0]. Returns the flattened
% values for the sub-array dims(lvl:end) (zero-padded; the string form
% returns the raw character codes).
global token strtext
S = prod(dims(min(lvl, numel(dims)):end));
vals = zeros(1, S);
i = 0;
if token == 123         % '{'
    next();
    while token ~= 125
        if token == 123
            % nested group: fills the remainder of the current sub-array
            if lvl < numel(dims)
                s = prod(dims(lvl+1:end));
                ext = s - mod(i, s);
            else
                ext = S - i;
            end
            sub = parse_arr_init(dims, lvl + 1);
            vals(i+1 : i+ext) = sub(1:ext);
            i = i + ext;
        else
            neg = 0;
            if token == 45
                neg = 1;
                next();
            end
            if token ~= 128
                fail('expected a constant array initializer');
            end
            if token_isflt
                % float patterns need exact 64-bit emission; the shared
                % numeric path cannot hold them (double arrays lose bits
                % beyond 2^53).  Runtime stores (assignment/expressions)
                % are the supported way to fill double arrays today.
                fail('float literal array initializers are not supported');
            end
            v = double(token_val);
            next();
            if neg
                v = -v;
            end
            if i >= S
                fail('too many array initializers');
            end
            vals(i+1) = v;
            i = i + 1;
        end
        if token == 44
            next();
        end
    end
    next();             % '}'
elseif token == 172     % string literal
    vals = double(strtext);
    next();
else
    fail('expected { or a string array initializer');
end
end

function parse_function_tail(fname2, ischarfn, rettype)
% after 'type name': '(' params ')' '{' <statements> return '}' — emit the
% per-function prologue, backpatch the frame size, and the epilogue.
global token out idname lvars lvartype lvararr lvarstruct fbytes funcs fret ...
       retlbl cfn cret cvoid glabels fparams frettype sret sretsize sretbase ginit fptypes
% ischarfn: 0/1 (char return); rettype: the full return type code (0 int,
% 1 char, 1000+2*stid struct). A struct return uses a hidden return pointer.
expect(40);                 % (
save_lvars = lvars;
save_lvartype = lvartype;
save_lvararr = lvararr;
save_lvarstruct = lvarstruct;
save_fbytes = fbytes;
save_glabels = glabels;
lvars = struct();
lvartype = struct();
lvararr = struct();
lvarstruct = struct();
glabels = struct();
fbytes = 0;
[nparams, psize, ptypes] = parse_params(rettype >= 1000);
expect(41);                 % )
expect(123);                % {
if isfield(funcs, fname2)
    fail(sprintf('duplicate function %s', fname2));
end
funcs.(fname2) = nparams;   % register before the body (recursion)
fret.(fname2) = rettype;    % full return type for call sites
frettype.(fname2) = rettype;
cret = ischarfn;
cvoid = (rettype == 4);     % void-returning (no value in rax)
sret = (rettype >= 1000);   % struct-returning
if sret
    sretsize = ssize_of(rettype);
    sretbase = 16 + 8 * nparams;
else
    sretsize = 0;
    sretbase = 0;
end
fparams.(fname2) = psize;   % the caller's per-arg copy sizes
fptypes.(fname2) = ptypes;  % the caller's per-arg type codes (codegen)
cfn = cfn + 1;
fn = cfn;
retlbl = sprintf('.Lret%d', fn);

em(sprintf('\t.globl\t%s', fname2));
em(sprintf('\t.def\t%s;\t.scl\t2;\t.type\t32;\t.endef', fname2));
em(sprintf('%s:', fname2));
em(sprintf('.LFB%d:', fn));
em('\t.cfi_startproc');
em('\tpushq\t%rbp');
em('\t.cfi_def_cfa_offset 16');
em('\t.cfi_offset 6, -16');
em('\tmovq\t%rsp, %rbp');
em('\t.cfi_def_cfa_register 6');
if strcmp(fname2, 'main') && ~isempty(ginit)
    % non-constant global initializers run in main's startup prologue
    for gk = 1:3:numel(ginit)
        gname = ginit{gk};
        gtype2 = ginit{gk+1};
        icodes = ginit{gk+2};
        for gkk = 1:numel(icodes)
            em(icodes{gkk});
        end
        if gtype2 == 1
            em(sprintf('\tmovb\t%%al, %s(%%rip)', gname));
        else
            em(sprintf('\tmovq\t%%rax, %s(%%rip)', gname));
        end
    end
end
frame_idx = em('\tsubq\t$0, %rsp');   % local frame; size backpatched

parse_body();
frame_sz = 16 * ceil(fbytes / 16);
out{frame_idx} = sprintf('\tsubq\t$%d, %%rsp', frame_sz);

expect(125);                % }
% any gotos to labels never defined in this function are errors
gnames = fieldnames(glabels);
for gk = 1:numel(gnames)
    if glabels.(gnames{gk}){1} == 0
        fail(sprintf('goto to undefined label %s', gnames{gk}));
    end
end
glabels = save_glabels;
em(sprintf('%s:', retlbl));   % target of every `return`
em('\tmovq\t%rbp, %rsp');   % discard the local frame
em('\tpopq\t%rbp');
em('\t.cfi_def_cfa 7, 8');
em('\tret');
em('\t.cfi_endproc');
em(sprintf('.LFE%d:', fn));

lvars = save_lvars;
lvartype = save_lvartype;
lvararr = save_lvararr;
lvarstruct = save_lvarstruct;
fbytes = save_fbytes;
end

function parse_globals(name, base, depth, fptr)
% global: name (('[' size ']')* | ('=' const|string|{…})? ) (',' name …)? ';'
% — collected for the .comm/.data section emitted at the end of the file.
% fptr: 1 for a global function pointer `type (*name)(params)`.
global token idname strtext globals gtype garr gstruct glist gstride gvararrsz out ginit token_isflt token_dval
while true
    if isfield(globals, name)
        fail(sprintf('duplicate global %s', name));
    end
    globals.(name) = 1;
    if fptr
        gtype.(name) = 2000 + base + 2 * depth;
        garr.(name) = 0;
        gstruct.(name) = 0;
        glist{end+1} = {name, 2002, 0, [], [], 0};
        if token == 44      % ','
            next();
            if token ~= 150
                fail('expected a name');
            end
            name = idname;
            next();
            continue;
        else
            break;
        end
    end
    t = base + 2 * depth;
    dims = [];
    isarr = 0;
    if token == 91          % '[': array (possibly multi-dimension)
        while token == 91
            next();
            if token ~= 128
                fail('expected a constant array size');
            end
            dims(end+1) = double(token_val);
            next();
            expect(93);
            if dims(end) < 0
                fail('bad array size');
            end
        end
        isarr = 1;
    end
    gtype.(name) = t + 2 * isarr;
    garr.(name) = isarr;
    gstruct.(name) = (~isarr) && (depth == 0) && (base >= 1000);
    if base >= 1000
        sbase = base;
    else
        sbase = 0;
    end
    if isarr && base >= 1000
        gstride.(name) = cstride_of(dims, ssize_of(base));
        gvararrsz.(name) = prod(dims) * ssize_of(base);
    elseif isarr && base == 1
        gstride.(name) = cstride_of(dims, 1);
        gvararrsz.(name) = prod(dims);
    elseif isarr
        gstride.(name) = cstride_of(dims, 8);
        gvararrsz.(name) = 8 * prod(dims);
    else
        gvararrsz.(name) = 0;
    end
    initv = [];
    if token == 61          % '=': constant initializer
        next();
        if isarr
            initv = parse_arr_init(dims, 1);
            if base == 1
                while numel(initv) < prod(dims)
                    initv(end+1) = 0;
                end
            end
        elseif token == 172     % string literal: pointer init
            initv = [double('S'), strtext];
            next();
        elseif ~isarr && base >= 1000 && depth == 0
            % struct-value initializer: { m1, m2, … } -> byte layout
            initv = {'B', struct_bytes(parse_struct_init(base), base)};
        else
            neg = 0;
            if token == 45      % '-'
                neg = 1;
                next();
            end
            if token == 128
                if token_isflt
                    % float literal: keep the exact IEEE pattern.  Stored
                    % as {'F', int64} so emit_globals can print exact hex.
                    pat = cc_d2bits(token_dval);
                    next();
                    if neg
                        pat = bitxor(pat, bitshift(int64(1), 63));
                    end
                    initv = {'F', pat};
                else
                    initv = double(token_val);
                    next();
                    if neg
                        initv = -initv;
                    end
                end
            elseif ~neg
                % non-constant initializer (a global, call, or expression):
                % evaluate in main's startup prologue, store to the global
                sav_out = out;
                out = {};
                parse_assignment();
                icodes = out;
                out = sav_out;
                ginit{end+1} = name;    % flat triples: {name, type, codes}
                ginit{end+1} = t;
                ginit{end+1} = icodes;
                initv = [];     % .comm (zero), then set at startup
            else
                fail('expected a constant global initializer');
            end
        end
    end
    glist{end+1} = {name, gtype.(name), isarr, dims, initv, sbase};
    if token == 44          % ','
        next();
        if token ~= 150
            fail('expected a name');
        end
        name = idname;
        next();
    else
        break;
    end
end
expect(59);                 % ;
end

function emit_globals()
% emit the .comm (uninitialized) and .data (initialized) global definitions,
% then the string literals.
global out glist strs
dat = 0;
for k = 1:numel(glist)
    g = glist{k};
    nm = g{1};
    t = g{2};
    isarr = g{3};
    dims = g{4};
    v = g{5};
    sbase = g{6};
    if isarr
        if mod(t, 2) == 1       % char-based element
            nbytes = prod(dims);
        elseif sbase ~= 0
            nbytes = prod(dims) * ssize_of(sbase);   % struct array
        else
            nbytes = 8 * prod(dims);
        end
    elseif t == 1
        nbytes = 1;
    elseif sbase ~= 0
        nbytes = ssize_of(sbase);   % a struct value
    else
        nbytes = 8;
    end
    if isempty(v)
        em(sprintf('	.comm	%s,%d,16', nm, nbytes));
    else
        if ~dat
            em('	.data');
            dat = 1;
        end
        em(sprintf('	.globl	%s', nm));
        em(sprintf('%s:', nm));
        if ~ischar(v) && numel(v) >= 1 && v(1) == double('S')
            % string-literal pointer initializer (marker 'S' + text)
            em(sprintf('	.quad	%s', new_str(v(2:end))));
        elseif iscell(v) && strcmp(v{1}, 'F')
            % double scalar initializer: exact 64-bit IEEE pattern
            em(sprintf('	.quad	0x%016X', v{2}));
        elseif iscell(v) && strcmp(v{1}, 'B')
            % struct-value initializer (marker cell 'B' + byte layout)
            line = '	.byte	';
            for kk = 1:numel(v{2})
                line = [line, sprintf('%d', v{2}(kk))];
                if kk < numel(v{2})
                    line = [line, ', '];
                end
            end
            em(line);
        elseif isarr
            % array initializer: values comma-separated (byte for char
            % elements, quad otherwise)
            line = '	.byte	';
            if mod(t, 2) ~= 1
                line = '	.quad	';
            end
            for kk = 1:numel(v)
                line = [line, sprintf('%d', v(kk))];
                if kk < numel(v)
                    line = [line, ', '];
                end
            end
            em(line);
        elseif t == 1
            em(sprintf('	.byte	%d', v));
        elseif t == 6
            % an int constant initializer for a double global: promote
            em(sprintf('	.quad	0x%016X', cc_d2bits(double(v))));
        else
            em(sprintf('	.quad	%d', v));
        end
    end
end
for k = 1:numel(strs)
    s = strs{k};
    em(sprintf('%s:', s{1}));
    txt = s{2};              % double code vector
    esc = [];
    for k = 1:numel(txt)
        c = txt(k);
        if c == 92 || c == 34     % escape backslash and quote for GAS
            esc = [esc, 92, c];
        elseif c == 10            % newline -> \n
            esc = [esc, 92, 110];
        else
            esc = [esc, c];
        end
    end
    em(sprintf('	.string	"%s"', char(esc)));
end
end

function isval = is_sval(t)
% is_sval — is t a struct VALUE type code (1000+2*stid, stid in 1..N)?
global sdefs
isval = (t >= 1002 && t <= 1000 + 2 * numel(sdefs));
end

function r = is_fptr_type(t)
% is_fptr_type — is t a function-pointer type (2000 + return type; struct
% returns are 3000+2*stid)?
r = (t >= 2000 && t < 2100) || t >= 3000;
end

function r = fptr_rettype(t)
% fptr_rettype — the return type of a function-pointer type t (0 int,
% 1 char, 1000+2*stid struct).
r = t - 2000;
end

function vals = parse_struct_init(sbase)
% parse_struct_init — `{ m1, m2, … }` for a struct-value initializer:
% member values in declaration order; a nested struct member takes a
% nested `{…}`. Returns the flattened leaf values (missing members -> 0
% via the caller's byte layout).
global token sdefs
next();                     % '{'
stid = (sbase - 1000) / 2;
names = sdefs{stid}{3};
vals = [];
for k = 1:numel(names)
    if token == 125
        break;              % remaining members are zero-initialized
    end
    minfo = sdefs{stid}{2}.(names{k});
    mt = minfo{2};
    if token == 123 && is_sval(mt)
        sub = parse_struct_init(mt);    % a nested struct value
        vals = [vals, sub];
    else
        neg = 0;
        if token == 45
            neg = 1;
            next();
        end
        if token ~= 128
            fail('expected a constant struct initializer');
        end
        v = double(token_val);
        next();
        if neg
            v = -v;
        end
        vals(end+1) = v;
    end
    if token == 44
        next();
    end
end
expect(125);
end

function bytes = struct_bytes(vals, sbase)
% struct_bytes — map the flattened leaf values to the struct's byte layout
% (little-endian; 1 byte for char members, 8 for int/pointer); missing
% leaves are zero.
global sdefs
stid = (sbase - 1000) / 2;
bytes = zeros(1, sdefs{stid}{1});
vi = 1;
[bytes, ~] = place_members(bytes, stid, vals, vi);
end

function [bytes, vi] = place_members(bytes, stid, vals, vi)
% place_members — recursive layout pass; vi is the next leaf value index.
global sdefs
names = sdefs{stid}{3};
for k = 1:numel(names)
    minfo = sdefs{stid}{2}.(names{k});
    off = minfo{1};
    mt = minfo{2};
    if is_sval(mt)
        if vi <= numel(vals)
            [bytes, vi] = place_members(bytes, (mt - 1000) / 2, vals, vi);
        end
    elseif vi <= numel(vals)
        v = vals(vi);
        vi = vi + 1;
        if mt == 1
            bytes(off+1) = mod(v, 256);
        else
            for b = 0:7
                bytes(off+b+1) = mod(floor(v / 2^(8*b)), 256);
            end
        end
    end
end
end

function lab = new_str(text)
% new_str — register a string literal, return its label (emitted later).
% The printf length modifiers are normalised (as in xc.m): %ls/%ld/%llu/
% %lu/%hd/%hs become %s/%d/%u/%u/%d/%s so the CRT printf agrees with the
% interpreter's mini-printf (whose %ls means a narrow string).
global strs nstr
lab = sprintf('.Lstr%d', nstr);
nstr = nstr + 1;
strs{end+1} = {lab, norm_codes(double(text))};   % stored as codes
end

function t = norm_codes(codes)
% norm_codes — code-vector version of norm_fmt (drop printf length
% modifiers l ll h hh j z t L before the conversion char).  The CLONE
% auto-calls a STRING argument that matches a function name ('sin'
% passed to a local function becomes callable), so format strings must
% never cross a local-function boundary as raw char arrays — they stay
% double code vectors here.
t = [];
i = 1;
nf = numel(codes);
while i <= nf
    if codes(i) ~= 37          % '%'
        t = [t, codes(i)];
        i = i + 1;
        continue;
    end
    j = i + 1;
    if j <= nf && codes(j) == 37
        t = [t, codes(i), codes(j)];   % literal percent
        i = j + 1;
        continue;
    end
    p = j;
    while p <= nf && ~((codes(p) >= 65 && codes(p) <= 90) || ...
                       (codes(p) >= 97 && codes(p) <= 122))
        p = p + 1;
    end
    k = p;
    while k <= nf && ~isempty(strfind('hljztL', char(codes(k))))
        k = k + 1;
    end
    if k > nf
        t = [t, codes(i)];     % a lone trailing '%': leave it
        break;
    end
    t = [t, codes(i), codes(j:p-1), codes(k)];
    i = k + 1;
end
end

function t = norm_fmt(fmt)
% norm_fmt — drop printf length modifiers (l, ll, h, hh, j, z, t, L) before
% the conversion char; flags/width/precision and everything else are kept.
t = '';
i = 1;
nf = numel(fmt);
while i <= nf
    if fmt(i) ~= 37          % '%'
        t = [t, fmt(i)];
        i = i + 1;
        continue;
    end
    j = i + 1;
    if j <= nf && fmt(j) == 37
        t = [t, '%%'];       % literal percent: no arg
        i = j + 1;
        continue;
    end
    p = j;
    while p <= nf && ~((fmt(p) >= 'A' && fmt(p) <= 'Z') || ...
                       (fmt(p) >= 'a' && fmt(p) <= 'z'))
        p = p + 1;
    end
    k = p;
    while k <= nf && ~isempty(strfind('hljztL', fmt(k)))
        k = k + 1;
    end
    if k > nf
        t = [t, fmt(i)];     % a lone trailing '%': leave it
        break;
    end
    t = [t, fmt(i), fmt(j:p-1), fmt(k)];
    i = k + 1;
end
end

function parse_body()
% parse_body — for void functions, statements until `}` (falling off the
% end is fine); otherwise main-style statements until the final top-level
% `return` (mirrors the tutorial — main must end with a return).
global token cvoid
if cvoid
    while token ~= 125          % '}'
        parse_statement();
    end
else
    while token ~= 130          % return
        parse_statement();
    end
    parse_return_statement();
end
end

function skip_prototype()
% skip_prototype — consume a function prototype's parameter list
% `(int a, char *b, …)` without binding anything.
expect(40);
depth = 0;
while true
    if token == 40
        depth = depth + 1;
    elseif token == 41
        if depth == 0
            break;
        end
        depth = depth - 1;
    end
    next();
end
next();                     % ')'
end

function [nparams, psize, ptypes] = parse_params(returns_struct)
% params := (type ('*')* name (('[' … ']')? (',' …)*))? — collect
% names/types first, then assign rbp offsets. Args are pushed left-to-right
% (arg1 deepest); by-value struct params occupy their full size, and a
% struct-returning function's hidden return pointer shifts the args by 8.
global token idname lvars lvartype lvararr lvarstruct sdefs
nparams = 0;
names = {};
types = {};
sizes = {};
bvs = {};
while token ~= 41           % ')'
    if token == 187         % 'void' alone: (void) — zero parameters
        next();             % leave the ')' for the caller's expect(41)
        break;
    end
    [base, stdef] = parse_basetype();
    if isa(stdef, 'cell')
        fail('struct definitions are not allowed in parameter lists');
    end
    depth = 0;
    while token == 42       % '*'
        depth = depth + 1;
        next();
    end
    if token ~= 150
        fail('expected a parameter name');
    end
    names{end+1} = idname;
    t = base + 2 * depth;
    next();
    decayed = 0;
    if token == 91          % '[': array parameter decays to a pointer
        while token == 91
            next();
            if token == 128
                next();
            end
            expect(93);
        end
        t = t + 2;
        decayed = 1;
    end
    types{end+1} = t;
    if base >= 1000 && depth == 0 && ~decayed
        sizes{end+1} = ssize_of(t);     % by-value struct
        bvs{end+1} = 1;
    else
        sizes{end+1} = 8;
        bvs{end+1} = 0;
    end
    if token == 44          % ','
        next();
    elseif token ~= 41
        fail('expected , or ) in the parameter list');
    end
end
nparams = numel(names);
% offsets: arg_k at base + sum of the sizes of the args above it
base = 16;
acc = 0;
for k = nparams:-1:1
    nm = names{k};
    if isfield(lvars, nm)
        fail(sprintf('duplicate parameter %s', nm));
    end
    lvars.(nm) = base + acc;
    lvartype.(nm) = types{k};
    lvararr.(nm) = 0;
    lvarstruct.(nm) = bvs{k};   % a by-value struct copy
    acc = acc + sizes{k};
end
psize = zeros(1, nparams);
ptypes = zeros(1, nparams);
for k = 1:nparams
    psize(k) = sizes{k};
    ptypes(k) = types{k};
end
end

function parse_statement()
% statement := declaration | '{' statement* '}' | if | while | for | do |
% break | continue | return | expr ';'
global token idname typedefs src si lvars lvartype lvararr lvarstruct lvarstride
if token == 131 || token == 134 || token == 178 || token == 188 || ...  % int/char/struct/unsigned
   token == 189 || token == 190 || token == 191 || token == 192 || ... % double/const/register/static
   (token == 150 && isfield(typedefs, idname))            % typedef'd type
    parse_declaration();
elseif token == 123         % '{': block — C scopes block locals: a
    % declaration inside is invisible outside, and sibling blocks may
    % reuse names.  Snapshot + restore the local maps around the block.
    next();
    save_blvars = lvars;       save_blvartype = lvartype;
    save_blvararr = lvararr;   save_blvarstruct = lvarstruct;
    save_blvarstride = lvarstride;
    while token ~= 125      % '}'
        parse_statement();
    end
    next();
    lvars = save_blvars;       lvartype = save_blvartype;
    lvararr = save_blvararr;   lvarstruct = save_blvarstruct;
    lvarstride = save_blvarstride;
elseif token == 151         % if
    parse_if();
elseif token == 152         % while
    parse_while();
elseif token == 173         % for
    parse_for();
elseif token == 174         % do
    parse_do();
elseif token == 182         % switch
    parse_switch();
elseif token == 175         % break
    parse_break();
elseif token == 176         % continue
    parse_continue();
elseif token == 186         % goto
    parse_goto();
elseif token == 185         % enum { … }; — register the constants
    parse_enum();
elseif token == 150         % Id: could be a label (`name:`) or an expression
    % peek one token for ':' without disturbing the lexer state
    save_si = si;
    save_tok = token;
    save_tv = token_val;
    save_id = idname;
    next();
    is_label = (token == 58);
    si = save_si; token = save_tok; token_val = save_tv; idname = save_id;
    if is_label
        define_label(idname);
    else
        parse_expression_statement();
    end
elseif token == 130         % return (nested in a block)
    parse_return_statement();
else
    parse_expression_statement();
end
end

function parse_goto()
% goto := 'goto' name ';' — a jump to the label (backpatched if the label
% is defined later).
global token idname glabels out
next();                     % 'goto'
if token ~= 150
    fail('expected a label name');
end
nm = idname;
next();
expect(59);
lab = sprintf('.Lgoto_%s', nm);
em(sprintf('\tjmp\t%s', lab));
if isfield(glabels, nm) && glabels.(nm){1} >= 0
    % label already defined: the jmp line is correct as-is
else
    % forward jump: record the line for backpatch
    ln = numel(out);
    if isfield(glabels, nm)
        glabels.(nm){3}(end+1) = ln;
    else
        glabels.(nm) = {0, ln, [ln]};
    end
end
end

function define_label(nm)
% define_label — `name:` — emit the label and backpatch pending gotos.
global token idname glabels out
if token ~= 150 || ~strcmp(idname, nm)
    fail('internal label error');
end
next();                     % the name
expect(58);                 % ':'
lab = sprintf('.Lgoto_%s', nm);
em(sprintf('%s:', lab));
ln = numel(out);
if isfield(glabels, nm) && glabels.(nm){1} ~= 0
    fail(sprintf('duplicate label %s', nm));
end
if isfield(glabels, nm)
    pend = glabels.(nm){3};
    glabels.(nm) = {ln, 0, []};
    for k = 1:numel(pend)
        out{pend(k)} = sprintf('\tjmp\t%s', lab);
    end
else
    glabels.(nm) = {ln, 0, []};
end
end

function parse_if()
% if := 'if' '(' expr ')' statement ('else' statement)? — uniform shape:
% je else-label / <then> / jmp end / else-label: [else] / end:
global token
next();                     % consume 'if'
expect(40);
parse_expr();
expect(41);
em('\tcmpq\t$0, %rax');
e1 = newlabel();
e2 = newlabel();
em(sprintf('\tje\t%s', e1));
parse_statement();
em(sprintf('\tjmp\t%s', e2));
em(sprintf('%s:', e1));
if token == 153             % else
    next();
    parse_statement();
end
em(sprintf('%s:', e2));
end

function parse_while()
% while := 'while' '(' expr ')' statement — break targets the end label,
% continue the start label.
global token loopctx
next();                     % consume 'while'
s = newlabel();
e = newlabel();
loopctx{end+1} = {e, s};
em(sprintf('%s:', s));
expect(40);
parse_expr();
expect(41);
em('\tcmpq\t$0, %rax');
em(sprintf('\tje\t%s', e));
parse_statement();
em(sprintf('\tjmp\t%s', s));
em(sprintf('%s:', e));
loopctx(end) = [];
end

function parse_for()
% for := 'for' '(' [init] ';' [cond] ';' [step] ')' statement
% Runtime order: init / s: cond / body / st: step / jmp s / e:. The step is
% token-wise BEFORE the body, so its emitted lines are buffered and spliced
% after the body.
global token idname typedefs loopctx out
next();                     % consume 'for'
expect(40);
if token ~= 59              % ';': optional init
    if token == 131 || token == 134 || token == 178 || token == 188 || ...
       token == 189 || token == 190 || token == 191 || token == 192 || ...
       (token == 150 && isfield(typedefs, idname))
        parse_declaration();      % `for (mwSize i = 0; ...)`; consumes ';'
    else
        parse_assignment();
        expect(59);
    end
end
if token ~= 59
    % a declaration init already consumed the ';'; skip the empty cond
else
    expect(59);
end
s = newlabel();
e = newlabel();
st = newlabel();
loopctx{end+1} = {e, st};
em(sprintf('%s:', s));
if token ~= 59              % optional condition
    parse_expr();
    em('\tcmpq\t$0, %rax');
    em(sprintf('\tje\t%s', e));
end
expect(59);
sn = numel(out);            % buffer the step's emitted lines
if token ~= 41              % optional step
    parse_assignment();
end
expect(41);
% copy the step's lines one-by-one (the clone's cell slicing with a
% vector/colon index returns empty — scalar {k} indexing works)
step_lines = {};
for kk = sn+1:numel(out)
    step_lines{end+1} = out{kk};
end
out(sn+1:numel(out)) = [];
parse_statement();          % the body
em(sprintf('%s:', st));     % continue target
for k = 1:numel(step_lines)
    out{end+1} = step_lines{k};
end
em(sprintf('\tjmp\t%s', s));
em(sprintf('%s:', e));
loopctx(end) = [];
end

function parse_do()
% do := 'do' statement 'while' '(' expr ')' ';' — break targets the end,
% continue the condition label.
global token loopctx
next();                     % consume 'do'
s = newlabel();
c = newlabel();
e = newlabel();
loopctx{end+1} = {e, c};
em(sprintf('%s:', s));
parse_statement();
em(sprintf('%s:', c));      % continue target
if token ~= 152             % 'while'
    fail('expected while after the do body');
end
next();
expect(40);
parse_expr();
expect(41);
em('\tcmpq\t$0, %rax');
em(sprintf('\tjne\t%s', s));
em(sprintf('%s:', e));
loopctx(end) = [];
expect(59);                 % ';'
end

function parse_switch()
% switch := 'switch' '(' expr ')' '{' (case const ':' stmts | default ':'
% stmts)* '}' — the value is kept in %r10; the dispatch (cmpq/je per case)
% is spliced before the case bodies, whose lines are buffered during the
% parse. break targets the switch end; continue the enclosing loop.
global token out loopctx enums idname
next();                     % 'switch'
expect(40);
parse_expr();
expect(41);
em('\tmovq\t%rax, %r10');   % the switch value
if token ~= 123
    fail('expected { after switch');
end
next();
sn = numel(out);
e = newlabel();
if isempty(loopctx)
    contl = e;
else
    contl = loopctx{end}{2};
end
loopctx{end+1} = {e, contl};
cases = {};
deflbl = '';
while token ~= 125          % '}'
    if token == 180         % case
        next();
        if token == 128          % numeric constant
            v = double(token_val);
            next();
        elseif token == 150 && isfield(enums, idname)   % enum constant
            v = double(enums.(idname));
            next();
        else
            fail('expected a case value');
        end
        expect(58);         % ':'
        l = newlabel();
        em(sprintf('%s:', l));
        cases{end+1} = {v, l};
    elseif token == 181     % default
        next();
        expect(58);
        deflbl = newlabel();
        em(sprintf('%s:', deflbl));
    else
        parse_statement();
    end
end
next();                     % '}'
em(sprintf('%s:', e));       % the break target (after all case bodies)
loopctx(end) = [];
% splice the dispatch before the case bodies (cell slicing is broken on
% the clone, so copy element-by-element)
body = {};
for k = sn+1:numel(out)
    body{end+1} = out{k};
end
out(sn+1:numel(out)) = [];
disp = {};
for k = 1:numel(cases)
    disp{end+1} = sprintf('\tcmpq\t$%d, %%r10', cases{k}{1});
    disp{end+1} = sprintf('\tje\t%s', cases{k}{2});
end
if ~isempty(deflbl)
    disp{end+1} = sprintf('\tjmp\t%s', deflbl);
else
    disp{end+1} = sprintf('\tjmp\t%s', e);
end
for k = 1:numel(disp)
    out{end+1} = disp{k};
end
for k = 1:numel(body)
    out{end+1} = body{k};
end
end

function parse_break()
% break := 'break' ';' — jump to the innermost loop's end label.
global token loopctx
if isempty(loopctx)
    fail('break outside a loop');
end
next();
expect(59);
em(sprintf('\tjmp\t%s', loopctx{end}{1}));
end

function parse_continue()
% continue := 'continue' ';' — jump to the innermost loop's step/cond label.
global token loopctx
if isempty(loopctx)
    fail('continue outside a loop');
end
next();
expect(59);
em(sprintf('\tjmp\t%s', loopctx{end}{2}));
end

function parse_return_statement()
% return := 'return' expr ';' — value in rax (zero-extended for char
% functions; for struct functions, the value is copied to the hidden return
% slot and rax = the slot address), jump to the function's epilogue label.
global retlbl cret cvoid sret sretbase
if cvoid
    expect(130);
    expect(59);             % 'return;' — no value
    em(sprintf('	jmp	%s', retlbl));
elseif sret
    expect(130);
    % parse the struct value expression into a temp, then copy it
    sn = numel(out);
    parse_expr();
    expect(59);
    st = sretsize;
    em(sprintf('\tmovq\t%d(%%rbp), %%rcx', sretbase));   % the hidden slot
    % copy st bytes from rax (the struct's address) to (rcx)
    for kk = 1:st/8
        em('\tmovq\t(%rax), %rdx');
        em('\tmovq\t%rdx, (%rcx)');
        em('\taddq\t$8, %rax');
        em('\taddq\t$8, %rcx');
    end
    em(sprintf('\tmovq\t%d(%%rbp), %%rax', sretbase));   % the slot address
    em(sprintf('\tjmp\t%s', retlbl));
else
    expect(130);
    parse_expr();
    expect(59);
    if cret
        em('\tmovzbl\t%al, %eax');
    end
    em(sprintf('\tjmp\t%s', retlbl));
end
end

function parse_declaration()
% declaration := type ('*')* name (('[' size ']')? (',' …)*) ('=' expr)? ';'
% — storage: char 1 byte, int/pointer 8, struct its size, arrays n*elem.
global token idname lvars lvartype lvararr lvarstruct lvarstride lvararrsz fbytes
[base, stdef] = parse_basetype();
if isa(stdef, 'cell')
    % a local struct definition: register the tag, then either the ';'
    % or a variable list of the new type (`struct Q { … } q;`)
    base = 1000 + 2 * register_struct(stdef{1}, stdef{2});
    if token == 59
        next();
        return;
    end
end
while true
    depth = 0;
    is_fptr = 0;
    while token == 42       % '*': return-type pointers (`int *(*fp)…`)
        depth = depth + 1;
        next();
    end
    if token == 40          % '(': function pointer `(*name)(params)`
        next();
        if token ~= 42
            fail('expected * for a function pointer');
        end
        next();
        is_fptr = 1;
    end
    if token ~= 150
        fail('expected a variable name');
    end
    name = idname;
    next();
    if is_fptr
        expect(41);             % ')'
        skip_prototype();       % (params): parsed and discarded
    end
    if isfield(lvars, name)
        fail(sprintf('duplicate local %s', name));
    end
    if is_fptr
        t = 2000 + base + 2 * depth;   % 2000 + the full return type
    else
        t = base + 2 * depth;
    end
    dims = [];
    isarr = 0;
    if token == 91          % '[': array (possibly multi-dimension)
        while token == 91
            next();
            if token ~= 128
                fail('expected a constant array size');
            end
            dims(end+1) = double(token_val);
            next();
            expect(93);
            if dims(end) < 0
                fail('bad array size');
            end
        end
        isarr = 1;
    end
    if isarr
        if t == 1
            elem = 1;
        elseif base >= 1000
            elem = ssize_of(base);
        else
            elem = 8;
        end
        nbytes = prod(dims) * elem;
        lvartype.(name) = t + 2;    % the name decays to a pointer
        lvararr.(name) = 1;
        lvarstruct.(name) = 0;
        lvarstride.(name) = cstride_of(dims, elem);
        lvararrsz.(name) = nbytes;
    elseif t == 1
        nbytes = 1;
        lvartype.(name) = t;
        lvararr.(name) = 0;
        lvarstruct.(name) = 0;
        lvararrsz.(name) = 0;
    elseif ~is_fptr && base >= 1000 && depth == 0
        nbytes = ssize_of(base);    % a struct value
        lvartype.(name) = t;
        lvararr.(name) = 0;
        lvarstruct.(name) = 1;
        lvararrsz.(name) = 0;
    else
        nbytes = 8;
        lvartype.(name) = t;
        lvararr.(name) = 0;
        lvarstruct.(name) = 0;
        lvararrsz.(name) = 0;
    end
    off = -(fbytes + nbytes);
    fbytes = fbytes + nbytes;
    lvars.(name) = off;
    if token == 61          % '=': initializer
        next();
        if isarr
            % constant array initializer: stores emitted directly
            vals = parse_arr_init(dims, 1);
            nelem = prod(dims);
            if t == 1
                elem = 1;
            elseif base >= 1000
                elem = ssize_of(base);
            else
                elem = 8;
            end
            if numel(vals) > nelem
                fail('too many array initializers');
            end
            while numel(vals) < nelem
                vals(end+1) = 0;    % C zero-fills the rest
            end
            for k = 1:numel(vals)
                if t == 1
                    em(sprintf('\tmovb\t$%d, %d(%%rbp)', vals(k), off + (k-1)));
                else
                    em(sprintf('\tmovq\t$%d, %d(%%rbp)', vals(k), off + (k-1)*elem));
                end
            end
        else
            parse_assignment();
            if t == 1
                em(sprintf('\tmovb\t%%al, %d(%%rbp)', off));
            elseif t == 6
                em(sprintf('\tmovsd\t%%xmm0, %d(%%rbp)', off));
            elseif base >= 1000 && depth == 0
                % struct value initializer: copy ssize bytes from rax
                em(sprintf('\tleaq\t%d(%%rbp), %%rcx', off));
                for kk = 1:ssize_of(base)/8
                    em('\tmovq\t(%rax), %rdx');
                    em('\tmovq\t%rdx, (%rcx)');
                    em('\taddq\t$8, %rax');
                    em('\taddq\t$8, %rcx');
                end
            else
                em(sprintf('\tmovq\t%%rax, %d(%%rbp)', off));
            end
        end
    end
    if token == 44          % ','
        next();
    else
        break;
    end
end
expect(59);                 % ;
end

function parse_expression_statement()
% expression_statement := expression ';' — the value is discarded.
parse_expr();
expect(59);
end

function parse_expr()
% expression := assignment (',' assignment)* — left-associative; the value
% is the last assignment's (the earlier ones are discarded).
global token
parse_assignment();
while token == 44           % ','
    next();
    parse_assignment();
end
end

function parse_conditional()
% conditional := logical_or ('?' assignment ':' conditional)? — the else
% branch is right-associative; the result is int-typed.
global token etype
parse_logical_or();
if token == 63              % '?'
    next();
    em('\tcmpq\t$0, %rax');
    f = newlabel();
    e = newlabel();
    em(sprintf('\tje\t%s', f));
    parse_assignment();
    t1 = etype;
    if token == 58          % ':'
        next();
    else
        fail('missing colon in conditional');
    end
    em(sprintf('\tjmp\t%s', e));
    em(sprintf('%s:', f));
    parse_conditional();
    t2 = etype;
    em(sprintf('%s:', e));
    if t1 == 6 || t2 == 6
        etype = 6;      % a double branch promotes the result
    else
        etype = 0;
    end
end
end

function parse_assignment()
% assignment := conditional (assign-op assignment)* — right-associative.
% The LHS must be an lvalue (its load is dropped, leaving the address);
% the address is pushed, the RHS evaluated, then stored, so the value (in
% eax) is the RHS — `y = x = 5` chains work. Compound ops load-modify-store
% and scale by the element size for pointer `+=`/`-=`.
global token out ltype etype sdefs bstride
parse_conditional();
while token == 61 || (token >= 160 && token <= 169)
    op = token;
    sav_ltype = ltype;      % the LHS's type (RHS parsing may change ltype)
    sav_bstride = bstride;  % the LHS's array strides (empty for scalars)
    sav_asz = curarrsz;     % the LHS array's total byte size (0 if not)
    if ~lvalue_addr()
        fail('bad lvalue in assignment');
    end
    if op == 61             % plain '='
        em('\tpushq\t%rax');
        next();
        parse_assignment();
        rhs_t = etype;      % the RHS expression's type
        em('\tpopq\t%rbx');
        if sav_ltype == 6 && rhs_t ~= 6
            % double lvalue, int RHS: promote to a double value
            em('\tcvtsi2sdq\t%rax, %xmm0');
        elseif rhs_t == 6 && sav_ltype ~= 1 && sav_ltype ~= 6
            % int/pointer lvalue, double RHS: truncate toward zero
            em('\tcvttsd2siq\t%xmm0, %rax');
        end
        if sav_ltype == 3 && ~isempty(sav_bstride)
            % string copy into a char array: copy the bytes until the NUL
            % or the array's size (rax keeps the source pointer)
            sz = sav_asz;
            em('\tmovq\t%rax, %rsi');     % source
            em('\tmovq\t%rbx, %rdi');     % dest
            em('\txorq\t%rcx, %rcx');
            cpl = newlabel();
            cpd = newlabel();
            em(sprintf('%s:', cpl));
            em(sprintf('\tcmpq\t$%d, %%rcx', sz));
            em(sprintf('\tjge\t%s', cpd));
            em('\tmovzbl\t(%rsi,%rcx), %edx');
            em('\tmovb\t%dl, (%rdi,%rcx)');
            em('\tincq\t%rcx');
            em('\ttestb\t%dl, %dl');
            em(sprintf('\tjne\t%s', cpl));
            em(sprintf('%s:', cpd));
        elseif sav_ltype == 1
            em('\tmovb\t%al, (%rbx)');
        elseif sav_ltype == 7
            em('\tmovw\t%ax, (%rbx)');
        elseif sav_ltype == 9
            em('\tmovl\t%eax, (%rbx)');
        elseif sav_ltype >= 1002 && sav_ltype <= 1000 + 2 * numel(sdefs)
            % struct-value assignment: copy the whole size (preserve rax)
            em('\tmovq\t%rax, %rcx');
            em('\tmovq\t%rbx, %rdx');
            st = ssize_of(sav_ltype);
            for kk = 1:st/8
                em('\tmovq\t(%rcx), %r8');
                em('\tmovq\t%r8, (%rdx)');
                em('\taddq\t$8, %rcx');
                em('\taddq\t$8, %rdx');
            end
        elseif sav_ltype == 6
            em('\tmovsd\t%xmm0, (%rbx)');
        else
            em('\tmovq\t%rax, (%rbx)');
        end
    elseif sav_ltype == 6
        % compound on a double lvalue: load-modify-store in %xmm
        em('\tpushq\t%rax');            % save the address
        em('\tmovsd\t(%rax), %xmm0');
        next();
        parse_assignment();
        if op == 163 || op == 164
            fail('compound "/=" and "%%=" on doubles are not supported');
        end
        if etype ~= 6
            em('\tcvtsi2sdq\t%rax, %xmm0');
        end
        % xmm0 = the RHS value; re-load the lvalue (the address is on
        % the stack) and combine
        em('\tpopq\t%rbx');             % the address
        em('\tmovsd\t(%rbx), %xmm1');   % old
        if op == 160
            em('\taddsd\t%xmm0, %xmm1');
        elseif op == 161
            em('\tsubsd\t%xmm0, %xmm1');
        elseif op == 162
            em('\tmulsd\t%xmm0, %xmm1');
        else
            em('\tdivsd\t%xmm0, %xmm1');
        end
        em('\tmovsd\t%xmm1, (%rbx)');
        em('\tmovsd\t%xmm1, %xmm0');
    else
        % compound: load-modify-store through the address
        em('\tpushq\t%rax');            % save the address
        if sav_ltype == 1
            em('\tmovzbl\t(%rax), %eax');
        elseif sav_ltype == 7
            em('\tmovzwl\t(%rax), %eax');
        elseif sav_ltype == 9
            em('\tmovl\t(%rax), %eax');
        else
            em('\tmovq\t(%rax), %rax');
        end
        em('\tpushq\t%rax');            % save the old value
        next();
        parse_assignment();
        if op == 165 || op == 166      % <<= >>= (count in %cl)
            em('\tmovq\t%rax, %rcx');
            em('\tpopq\t%rax');
            if op == 165
                em('\tshlq\t%cl, %rax');
            elseif sav_ltype == 5
                em('\tshrq\t%cl, %rax');   % logical (unsigned lvalue)
            else
                em('\tsarq\t%cl, %rax');   % arithmetic (signed)
            end
        else
            em('\tmovq\t%rax, %rbx');   % rhs
            if (op == 160 || op == 161) && sav_ltype >= 2 && sav_ltype ~= 3
                em(sprintf('\timulq\t$%d, %%rbx', elem_size(sav_ltype)));
            end
            em('\tpopq\t%rax');         % old value
            if op == 160        % +=
                em('\taddq\t%rbx, %rax');
            elseif op == 161    % -=
                em('\tsubq\t%rbx, %rax');
            elseif op == 162    % *=
                em('\timulq\t%rbx, %rax');
            elseif op == 163 || op == 164   % /= %%=
                em('\tcqto');
                em('\tidivq\t%rbx');
                if op == 164
                    em('\tmovq\t%rdx, %rax');
                end
            elseif op == 167    % &=
                em('\tandq\t%rbx, %rax');
            elseif op == 168    % |=
                em('\torq\t%rbx, %rax');
            else                % ^=
                em('\txorq\t%rbx, %rax');
            end
        end
        em('\tpopq\t%rbx');              % the address
        if sav_ltype == 1
            em('\tmovb\t%al, (%rbx)');
        else
            em('\tmovq\t%rax, (%rbx)');
        end
    end
    etype = sav_ltype;      % the assignment's value has the lvalue's type
end
end

function parse_logical_or()
% logical_or := logical_and ('||' logical_and)* — short-circuit: a
% nonzero operand jumps straight to set-the-result-to-1.
global token etype
parse_logical_and();
while token == 143           % Lor
    next();
    t = newlabel();
    e = newlabel();
    em('\tcmpq\t$0, %rax');
    em(sprintf('\tjne\t%s', t));
    parse_logical_and();
    em('\tcmpq\t$0, %rax');
    em(sprintf('\tjne\t%s', t));
    em('\tmovq\t$0, %rax');
    em(sprintf('\tjmp\t%s', e));
    em(sprintf('%s:', t));
    em('\tmovq\t$1, %rax');
    em(sprintf('%s:', e));
    etype = 0;
end
end

function parse_logical_and()
% logical_and := bitwise_or ('&&' bitwise_or)* — short-circuit: a zero
% operand jumps straight to set-the-result-to-0.
global token etype
parse_bit_or();
while token == 142           % Lan
    next();
    f = newlabel();
    e = newlabel();
    em('\tcmpq\t$0, %rax');
    em(sprintf('\tje\t%s', f));
    parse_bit_or();
    em('\tcmpq\t$0, %rax');
    em(sprintf('\tje\t%s', f));
    em('\tmovq\t$1, %rax');
    em(sprintf('\tjmp\t%s', e));
    em(sprintf('%s:', f));
    em('\tmovq\t$0, %rax');
    em(sprintf('%s:', e));
    etype = 0;
end
end

function l = newlabel()
% newlabel — a fresh unique assembly label for short-circuit jumps.
global lbl
lbl = lbl + 1;
l = sprintf('.Llo%d', lbl);
end

function parse_bit_or()
% bitwise_or := bitwise_xor ('|' bitwise_xor)*
global token etype
parse_bit_xor();
while token == 124          % '|'
    next();
    em('\tpushq\t%rax');    % save the left operand
    parse_bit_xor();
    em('\tmovq\t%rax, %rbx');
    em('\tpopq\t%rax');
    em('\torq\t%rbx, %rax');
    etype = 0;
end
end

function parse_bit_xor()
% bitwise_xor := bitwise_and ('^' bitwise_and)*
global token etype
parse_bit_and();
while token == 94           % '^'
    next();
    em('\tpushq\t%rax');
    parse_bit_and();
    em('\tmovq\t%rax, %rbx');
    em('\tpopq\t%rax');
    em('\txorq\t%rbx, %rax');
    etype = 0;
end
end

function parse_bit_and()
% bitwise_and := equality ('&' equality)*
global token etype
parse_equality();
while token == 38           % '&'
    next();
    em('\tpushq\t%rax');
    parse_equality();
    em('\tmovq\t%rax, %rbx');
    em('\tpopq\t%rax');
    em('\tandq\t%rbx, %rax');
    etype = 0;
end
end

function parse_equality()
% equality := relational (('==' | '!=') relational)* — result 0/1 via setcc
global token etype
parse_relational();
while token == 148 || token == 149   % Eq Ne
    op = token;
    next();
    sav_etype = etype;
    if sav_etype == 6
        em('\tsubq\t$8, %rsp');
        em('\tmovsd\t%xmm0, (%rsp)');
    else
        em('\tpushq\t%rax');
    end
    parse_relational();
    rhs_t = etype;
    if sav_etype == 6 || rhs_t == 6
        % double equality: NaN is unordered (ZF=0) so == is false and
        % != is true, exactly matching C.
        if rhs_t == 6
            em('\tmovsd\t%xmm0, %xmm0');   % R stays in xmm0
        else
            em('\tcvtsi2sdq\t%rax, %xmm0');
        end
        if sav_etype == 6
            em('\tmovsd\t(%rsp), %xmm1');
            em('\taddq\t$8, %rsp');
        else
            em('\tcvtsi2sdq\t(%rsp), %xmm1');
        em('\taddq\t$8, %rsp');
        end
        em('\tucomisd\t%xmm0, %xmm1');
        if op == 148
            em('\tsete\t%al');
        else
            em('\tsetne\t%al');
        end
        em('\tmovzbl\t%al, %eax');
        etype = 0;
    else
        em('\tmovq\t%rax, %rbx');   % R -> rbx
        em('\tpopq\t%rax');   % L -> rax
        em('\tcmpq\t%rbx, %rax');
        if op == 148
            em('\tsete\t%al');
        else
            em('\tsetne\t%al');
        end
        em('\tmovzbl\t%al, %eax');
        etype = 0;
    end
end
end

function parse_relational()
% relational := shift (('<' | '>' | '<=' | '>=') shift)* — signed
% comparisons; eax = left, ebx = right, so setl/setg/etc. read eax-ebx.
global token etype
parse_shift();
while token == 144 || token == 145 || token == 146 || token == 147  % Lt Gt Le Ge
    op = token;
    sav_etype = etype;
    next();
    if sav_etype == 6
        em('\tsubq\t$8, %rsp');
        em('\tmovsd\t%xmm0, (%rsp)');
    else
        em('\tpushq\t%rax');
    end
    parse_shift();
    rhs_t = etype;
    if sav_etype == 6 || rhs_t == 6
        % double comparison: values; L -> %xmm1, R -> %xmm0, then
        % ucomisd b-a with b=%xmm1 (L), a=%xmm0 (R).
        if rhs_t == 6
            em('\tmovsd\t%xmm0, %xmm0');   % R stays in xmm0
        else
            em('\tcvtsi2sdq\t%rax, %xmm0');
        end
        if sav_etype == 6
            em('\tmovsd\t(%rsp), %xmm1');
            em('\taddq\t$8, %rsp');
        else
            em('\tcvtsi2sdq\t(%rsp), %xmm1');
        em('\taddq\t$8, %rsp');
        end
        em('\tucomisd\t%xmm0, %xmm1');
        if op == 144        % Lt: CF && !PF
            em('\tsetb\t%al');
            em('\tsetnp\t%cl');
            em('\tandb\t%cl, %al');
        elseif op == 145    % Gt: CF=0 && ZF=0
            em('\tseta\t%al');
        elseif op == 146    % Le: (CF || ZF) && !PF
            em('\tsetbe\t%al');
            em('\tsetnp\t%cl');
            em('\tandb\t%cl, %al');
        else                % Ge: CF=0
            em('\tsetae\t%al');
        end
        em('\tmovzbl\t%al, %eax');
        etype = 0;
    else
        em('\tmovq\t%rax, %rbx');   % R -> rbx
        em('\tpopq\t%rax');   % L -> rax
        em('\tcmpq\t%rbx, %rax');
        if op == 144        % Lt
        if sav_etype == 5
            em('\tsetb\t%al');     % unsigned: below
        else
            em('\tsetl\t%al');
        end
    elseif op == 145    % Gt
        if sav_etype == 5
            em('\tseta\t%al');     % unsigned: above
        else
            em('\tsetg\t%al');
        end
    elseif op == 146    % Le
        if sav_etype == 5
            em('\tsetbe\t%al');    % unsigned: below-or-equal
        else
            em('\tsetle\t%al');
        end
    else                % Ge
        if sav_etype == 5
            em('\tsetae\t%al');    % unsigned: above-or-equal
        else
            em('\tsetge\t%al');
        end
    end
    em('\tmovzbl\t%al, %eax');
    etype = 0;
    end
end
end

function parse_shift()
% shift := additive (('<<' | '>>') additive)* — left-associative; the shift
% count goes in %cl; '>>' is an arithmetic shift (signed int).
global token etype
parse_additive();
while token == 140 || token == 141   % Shl Shr
    op = token;
    sav_etype = etype;
    next();
    em('\tpushq\t%rax');        % save the left operand
    parse_additive();
    em('\tmovq\t%rax, %rcx');   % shift count in %cl
    em('\tpopq\t%rax');
    if op == 140
        em('\tshlq\t%cl, %rax');
    elseif sav_etype == 5
        em('\tshrq\t%cl, %rax');   % logical (unsigned)
    else
        em('\tsarq\t%cl, %rax');   % arithmetic (signed)
    end
    etype = 0;
end
end

function parse_additive()
% additive := term (('+' | '-') term)* — pointer operands scale the
% integer by the element size (1 for char*, 4 otherwise); ptr - ptr gives
% the element difference.  Double operands live in %xmm0 (value model);
% the left operand is saved on the xmm-stack (double) or on the stack (int)
% so a call inside the right operand cannot corrupt it.
global token etype
parse_term();
while token == 43 || token == 45   % '+' '-'
    op = token;
    t = etype;              % the left operand's type
    next();
    if t == 6
        em('\tsubq\t$8, %rsp');
        em('\tmovsd\t%xmm0, (%rsp)');
    else
        em('\tpushq\t%rax');   % int/ptr left
    end
    parse_term();
    rhs_t = etype;
    if t == 6 || rhs_t == 6
        % double arithmetic (usual arithmetic conversions); L in %xmm0
        % (xmm-stack) or the stack, R in %xmm0 (double) or %rax (int)
        if rhs_t == 6
            em('\tmovsd\t%xmm0, %xmm1');   % R -> xmm1
            if t == 6
                em('\tmovsd\t(%rsp), %xmm0');
                em('\taddq\t$8, %rsp');
            else
                em('\tcvtsi2sdq\t(%rsp), %xmm0');
        em('\taddq\t$8, %rsp');
            end
        else
            if t == 6
                em('\tmovsd\t(%rsp), %xmm0');
                em('\taddq\t$8, %rsp');
            else
                em('\tcvtsi2sdq\t(%rsp), %xmm0');
        em('\taddq\t$8, %rsp');
            end
            em('\tcvtsi2sdq\t%rax, %xmm1');
        end
        if op == 43
            em('\taddsd\t%xmm1, %xmm0');
        else
            em('\tsubsd\t%xmm1, %xmm0');
        end
        etype = 6;
    elseif t >= 2 && t ~= 7 && t ~= 9   % the left is a pointer (the
        % 2-/4-byte integer VALUE codes 7/9 are not pointers; only their
        % pointer codes 9/11 are)
        em('\tmovq\t%rax, %rbx');   % R -> rbx
        em('\tpopq\t%rax');   % L
        if op == 45 && rhs_t >= 2
            % ptr - ptr: byte difference / element size
            em('\tsubq\t%rbx, %rax');
            if t ~= 3
                em(sprintf('\tmovq\t$%d, %%rcx', elem_size(t)));
                em('\tcqto');
                em('\tidivq\t%rcx');
            end
            etype = 0;
        else
            if t ~= 3       % char*: element size 1 — no scaling
                em(sprintf('\timulq\t$%d, %%rbx', elem_size(t)));
            end
            if op == 43
                em('\taddq\t%rbx, %rax');
            else
                em('\tsubq\t%rbx, %rax');
            end
            etype = t;      % still a pointer
        end
    else
        % int op int
        em('\tmovq\t%rax, %rbx');   % R -> rbx
        em('\tpopq\t%rax');   % L
        if op == 43
            em('\taddq\t%rbx, %rax');
        else
            em('\tsubq\t%rbx, %rax');
        end
        etype = 0;
    end
end
end

function parse_term()
% term := unary (('*' | '/' | '%') unary)* — left-associative.  Integer
% '/' and '%' use cqto/idivq (truncation toward zero, C semantics);
% doubles use mulsd/divsd on the %xmm0 value model with the left saved
% on the xmm-stack / the stack as in parse_additive.
global token etype
parse_unary();
while token == 42 || token == 47 || token == 37   % '*' '/' '%'
    op = token;
    sav_etype = etype;      % the dividend's type (unsigned -> divq)
    next();
    if sav_etype == 6
        em('\tsubq\t$8, %rsp');
        em('\tmovsd\t%xmm0, (%rsp)');
    else
        em('\tpushq\t%rax');
    end
    parse_unary();
    rhs_t = etype;
    if sav_etype == 6 || rhs_t == 6
        % double multiplication/division (usual arithmetic conversions)
        if op == 37
            fail('%% on doubles is not supported');
        end
        if rhs_t == 6
            em('\tmovsd\t%xmm0, %xmm1');
            if sav_etype == 6
                em('\tmovsd\t(%rsp), %xmm0');
                em('\taddq\t$8, %rsp');
            else
                em('\tcvtsi2sdq\t(%rsp), %xmm0');
        em('\taddq\t$8, %rsp');
            end
        else
            if sav_etype == 6
                em('\tmovsd\t(%rsp), %xmm0');
                em('\taddq\t$8, %rsp');
            else
                em('\tcvtsi2sdq\t(%rsp), %xmm0');
        em('\taddq\t$8, %rsp');
            end
            em('\tcvtsi2sdq\t%rax, %xmm1');
        end
        if op == 42
            em('\tmulsd\t%xmm1, %xmm0');
        else
            em('\tdivsd\t%xmm1, %xmm0');
        end
        etype = 6;
    else
        em('\tmovq\t%rax, %rbx');   % rhs
        em('\tpopq\t%rax');   % lhs
        if op == 42
            em('\timulq\t%rbx, %rax');
        elseif sav_etype == 5
            em('\txorq\t%rdx, %rdx');
            em('\tdivq\t%rbx');        % unsigned
            if op == 37
                em('\tmovq\t%rdx, %rax');
            end
        else
            em('\tcqto');
            em('\tidivq\t%rbx');
            if op == 37
                em('\tmovq\t%rdx, %rax');
            end
        end
        if sav_etype ~= 6 && rhs_t ~= 6
            etype = 0;
        end
    end
end
end

function parse_unary()
% unary := prefix* primary postfix*; primary := Num | Str | Id | '(' expr ')'
% postfix := '[' expr ']' | '.' name | '->' name | '++' | '--'. Prefix ops
% apply in reverse. Types: etype tracks the type; arrays and struct values
% decay (no load, estruc = 1 for struct values).
global token token_val token_dval token_isflt idname strtext lvars lvartype lvararr lvarstruct ...
       globals gtype garr gstruct funcs fret frettype fparams called ltype libfns libcalls ...
       etype estruc lvarstride gstride bstride lvararrsz gvararrsz curarrsz si typedefs fbytes fptypes libargt libret
ops = [];
while token == 45 || token == 126 || token == 33 || token == 43 || ...   % - ~ ! +
      token == 38 || token == 42 || token == 170 || token == 171          % & * ++ --
    ops = [ops, token];
    next();
end
if token == 40              % '(': a cast (type)unary or parenthesised expr
    % peek one token: a type keyword (or a typedef'd name) means a cast
    save_si = si;
    save_tok = token;
    save_tv = token_val;
    save_id = idname;
    next();
    is_cast = (token == 131 || token == 134 || token == 178 || token == 187 || ...
              token == 189 || ...
              (token == 150 && isfield(typedefs, idname)));
    si = save_si; token = save_tok; token_val = save_tv; idname = save_id;
    if is_cast
        next();             % '('
        [cbase, cstdef] = parse_basetype();
        if isa(cstdef, 'cell')
            fail('struct definitions are not allowed in casts');
        end
        cdepth = 0;
        while token == 42   % '*'
            cdepth = cdepth + 1;
            next();
        end
        cl_dims = [];
        cl_isarr = 0;
        if token == 91      % '[': a compound-literal array size
            while token == 91
                next();
                if token == 128
                    cl_dims(end+1) = double(token_val);
                    next();
                end
                expect(93);
            end
            cl_isarr = 1;
        end
        expect(41);         % ')'
        if token == 123     % '{': a compound literal
            % a stack temp initialized from the constant elements; the
            % value is the temp's address (an lvalue, like C99)
            if cdepth > 0
                fail('pointer compound literals are not supported');
            end
            if cbase >= 1000 && ~cl_isarr
                % (struct P){…}: a struct value
                vals = parse_struct_init(cbase);
                bytes = struct_bytes(vals, cbase);
                nbytes = numel(bytes);
                off = -(fbytes + nbytes);
                fbytes = fbytes + nbytes;
                for k = 1:numel(bytes)
                    em(sprintf('\tmovb\t$%d, %d(%%rbp)', bytes(k), off + k - 1));
                end
                em(sprintf('\tleaq\t%d(%%rbp), %%rax', off));
                etype = cbase;
                estruc = 1;
            elseif cl_isarr || cbase == 0 || cbase == 1
                % (int[3]){…} / (int[]){…} / (char[..]){…}: an array
                elem = 8;
                if cbase == 1
                    elem = 1;
                end
                if isempty(cl_dims)
                    % unsized: count the top-level elements (peek)
                    cs_si = si; cs_tok = token; cs_tv = token_val; cs_id = idname;
                    next();
                    cnt = 0;
                    while token ~= 125
                        if token == 123
                            d2 = 1;
                            next();
                            while d2 > 0
                                if token == 123
                                    d2 = d2 + 1;
                                elseif token == 125
                                    d2 = d2 - 1;
                                end
                                next();
                            end
                        else
                            next();
                        end
                        cnt = cnt + 1;
                        if token == 44
                            next();
                        end
                    end
                    si = cs_si; token = cs_tok; token_val = cs_tv; idname = cs_id;
                    cl_dims = [cnt];
                end
                vals = parse_arr_init(cl_dims, 1);
                nbytes = prod(cl_dims) * elem;
                off = -(fbytes + nbytes);
                fbytes = fbytes + nbytes;
                for k = 1:numel(vals)
                    if elem == 1
                        em(sprintf('\tmovb\t$%d, %d(%%rbp)', vals(k), off + k - 1));
                    else
                        em(sprintf('\tmovq\t$%d, %d(%%rbp)', vals(k), off + 8 * (k - 1)));
                    end
                end
                em(sprintf('\tleaq\t%d(%%rbp), %%rax', off));
                etype = cbase + 2;
                estruc = 0;
            else
                % (int){5}: a scalar compound literal
                next();
                neg = 0;
                if token == 45
                    neg = 1;
                    next();
                end
                if token ~= 128
                    fail('expected a constant compound literal');
                end
                v = double(token_val);
                next();
                if neg
                    v = -v;
                end
                if cbase == 1
                    em(sprintf('\tmovb\t$%d, -1(%%rbp)', mod(v, 256)));
                    fbytes = max(fbytes, 1);
                    em('\tleaq\t-1(%rbp), %rax');
                    etype = 1;
                else
                    off = -(fbytes + 8);
                    fbytes = fbytes + 8;
                    em(sprintf('\tmovq\t$%d, %d(%%rbp)', v, off));
                    em(sprintf('\tleaq\t%d(%%rbp), %%rax', off));
                    etype = 0;
                end
                estruc = 0;
            end
        else
            parse_unary();      % the operand (cast-expression = unary)
            if cbase == 6 && cdepth == 0
                % (double)x: int/char -> double (value into %xmm0)
                if etype ~= 6
                    em('\tcvtsi2sdq\t%rax, %xmm0');
                end
            elseif (cbase == 0 || cbase == 5 || cbase == 7 || cbase == 9) ...
                    && cdepth == 0 && etype == 6
                % (int)x / (unsigned)x / (int16_t)x / (int32_t)x :
                % double -> int (truncate toward 0)
                em('\tcvttsd2siq\t%xmm0, %rax');
            elseif cbase == 1 && cdepth == 0
                if etype == 6
                    em('\tcvttsd2siq\t%xmm0, %rax');
                end
                em('\tmovsbl\t%al, %eax');   % truncate to a signed char
            end
            etype = cbase + 2 * cdepth;
            estruc = 0;
        end
    else
        next();
        parse_expr();       % parenthesised expression (may contain ',')
        expect(41);
    end
elseif token == 128         % Num
    if token_isflt
        % a double literal: movabsq $0x<pattern>, %rax.  The exact
        % 64-bit hex form is parsed exactly by x86sim (sim_num64); the
        % ordinary decimal form would lose precision for large patterns.
        em(sprintf('\tmovabsq\t$0x%016X, %%rax', cc_d2bits(token_dval)));
        em('\tmovq\t%rax, %xmm0');
        etype = 6;
    else
        em(sprintf('\tmovq\t$%d, %%rax', double(token_val)));
        etype = 0;
    end
    estruc = 0;
    next();
elseif token == 183         % sizeof: type or expression
    next();
    if token ~= 40
        % sizeof expr (unparenthesized, C grammar also allows this):
        % parse for the type, drop the emitted code； an array name
        % yields its whole byte size
        sn = numel(out);
        parse_assignment();
        if etype == 1
            sz = 1;
        elseif curarrsz > 0
            sz = curarrsz;      % a whole array: its total byte size
        elseif estruc
            sz = ssize_of(etype);
        else
            sz = 8;
        end
        out(sn+1:numel(out)) = [];
        em(sprintf('\tmovq\t$%d, %%rax', sz));
        etype = 0;
        estruc = 0;
    elseif token == 40
        next();
        if token == 131 || token == 134 || token == 178 || token == 189   % a type
            [base, stdef] = parse_basetype();
            depth = 0;
            while token == 42       % '*'
                depth = depth + 1;
                next();
            end
            if base == 1 && depth == 0
                sz = 1;
            elseif base >= 1000 && depth == 0
                sz = ssize_of(base);
            else
                sz = 8;
            end
            expect(41);
        else
            % sizeof(expr): parse for the type, drop the emitted code
            sn = numel(out);
            parse_assignment();
            expect(41);
            if etype == 1
                sz = 1;
            elseif curarrsz > 0
                sz = curarrsz;      % a whole array: its total byte size
            elseif estruc
                sz = ssize_of(etype);
            else
                sz = 8;
            end
            out(sn+1:numel(out)) = [];
        end
        em(sprintf('\tmovq\t$%d, %%rax', sz));
        etype = 0;
        estruc = 0;
    end
elseif token == 172         % Str: string literal -> char* to .Lstr data
    lab = new_str(strtext);
    em(sprintf('\tleaq\t%s(%%rip), %%rax', lab));
    etype = 3;              % char*
    estruc = 0;
    next();
elseif token == 150         % Id: function call or variable
    name = idname;
    next();
    if token == 40 && (isfield(funcs, name) || ~(isfield(lvars, name) || ...
       isfield(globals, name) || isfield(enums, name)))   % '(': a call
        next();
        % struct-returning callee: reserve the return slot and push a
        % hidden pointer to it (the callee copies its result there)
        sret_call = 0;
        if isfield(frettype, name) && frettype.(name) >= 1000
            sret_call = 1;
            rsz = ssize_of(frettype.(name));
            em(sprintf('\tsubq\t$%d, %%rsp', rsz));
            em('\tmovq\t%rsp, %rax');
            em('\tpushq\t%rax');
        end
        nargs = 0;
        if token ~= 41      % ')'
            while true
                parse_assignment();
                at = etype;
                % declared parameter type: promote int -> double or
                % truncate double -> int at the call boundary (C function
                % prototype semantics).  User functions use fptypes;
                % math intrinsics carry libargt.  Varargs (no entry) are
                % passed through untouched (bit patterns).
                dt = [];
                if isfield(fptypes, name) && nargs + 1 <= numel(fptypes.(name))
                    dt = fptypes.(name)(nargs + 1);
                elseif isfield(libargt, name) && nargs + 1 <= numel(libargt.(name))
                    dt = libargt.(name)(nargs + 1);
                end
                if ~isempty(dt) && dt == 6 && at ~= 6
                    em('\tcvtsi2sdq\t%rax, %xmm0');
                elseif ~isempty(dt) && dt ~= 6 && at == 6
                    em('\tcvttsd2siq\t%xmm0, %rax');
                end
                pushed = 0;
                if at == 6 || dt == 6
                    % a double-typed argument: its VALUE lives in %xmm0
                    % and is pushed onto the stack directly
                    em('\tsubq\t$8, %rsp');
                    em('\tmovsd\t%xmm0, (%rsp)');
                    pushed = 1;
                end
                % by-value struct arg: copy the full size instead of
                % pushing one word (the callee's declared param sizes)
                asz = 8;
                if pushed
                    asz = 0;    % already on the stack
                elseif isfield(fparams, name) && nargs + 1 <= numel(fparams.(name))
                    asz = fparams.(name)(nargs + 1);
                elseif estruc
                    asz = ssize_of(etype);
                end
                if asz > 8 || estruc
                    em('\tmovq\t%rax, %rdx');
                    for kk = 1:asz/8
                        em('\tmovq\t(%rdx), %r8');
                        em('\tpushq\t%r8');
                        em('\taddq\t$8, %rdx');
                    end
                elseif ~pushed
                    em('\tpushq\t%rax');
                end
                nargs = nargs + 1;
                if token == 44    % ','
                    next();
                else
                    break;
                end
            end
        end
        expect(41);
        if isfield(funcs, name) && funcs.(name) ~= nargs
            fail(sprintf('function %s called with %d args, takes %d', ...
                name, nargs, funcs.(name)));
        end
        if isfield(called, name)
            called.(name) = [called.(name), nargs];   % per-call-site counts
        else
            called.(name) = nargs;
        end
        if isfield(libfns, name)
            % runtime-library call: go through the shim; the simulator
            % implements <name> (dispatches on the symbol, not the CRT)
            libcalls.(sprintf('%s_%d', name, nargs)) = 1;
            em(sprintf('\tcall\t__cc_%s_%d', name, nargs));
            if isfield(libret, name)
                etype = libret.(name);   % 8 ptr, 6 double, 0 int, 4 void
                if etype == 4
                    etype = 0;
                end
            end
        else
            em(sprintf('\tcall\t%s', name));
        end
        if sret_call
            % pop args, the hidden slot pointer, AND the return slot
            em(sprintf('\taddq\t$%d, %%rsp', 8 * (nargs + 1) + rsz));
            estruc = 1;      % the result is a struct value (slot address)
        else
            if nargs > 0
                em(sprintf('\taddq\t$%d, %%rsp', 8 * nargs));
            end
            estruc = 0;
        end
        if isfield(fret, name)
            etype = fret.(name);
        elseif ~(isfield(libfns, name) && isfield(libret, name))
            etype = 0;
        end
        if sret_call
            etype = frettype.(name);   % the struct type
        end
    else
        % variable: local/param (rbp) or global (rip); arrays and struct
        % values skip the load (their address is the value); enum constants
        % are immediates.
        isval = 0;
        if isfield(lvars, name)
            t = lvartype.(name);
            isarr = lvararr.(name);
            isst = lvarstruct.(name);
            em(sprintf('\tleaq\t%d(%%rbp), %%rax', lvars.(name)));
        elseif isfield(globals, name)
            t = gtype.(name);
            isarr = garr.(name);
            isst = gstruct.(name);
            em(sprintf('\tleaq\t%s(%%rip), %%rax', name));
        elseif isfield(enums, name)
            em(sprintf('\tmovq\t$%d, %%rax', enums.(name)));
            etype = 0;
            estruc = 0;
            isval = 1;
        elseif isfield(funcs, name)
            % a bare function name: its address (for function pointers)
            em(sprintf('\tleaq\t%s(%%rip), %%rax', name));
            etype = 2;
            estruc = 0;
            isval = 1;
        else
            fail(sprintf('undefined variable %s', name));
        end
        if ~isval
            etype = t;
            if isarr
                if isfield(lvars, name)
                    bstride = lvarstride.(name);
                    curarrsz = lvararrsz.(name);
                else
                    bstride = gstride.(name);
                    curarrsz = gvararrsz.(name);
                end
            else
                bstride = [];
                curarrsz = 0;
            end
            if isst
                estruc = 1;         % a struct value: address already in rax
            else
                estruc = 0;
                if ~isarr
                    if t == 1
                        em('\tmovzbl\t(%rax), %eax');
                    elseif t == 7
                        em('\tmovzwl\t(%rax), %eax');
                    elseif t == 9
                        em('\tmovl\t(%rax), %eax');
                    elseif t == 6
                        % a double VARIABLE load: value to %xmm0
                        em('\tmovsd\t(%rax), %xmm0');
                    else
                        em('\tmovq\t(%rax), %rax');
                    end
                end
            end
        end
    end
else
    fail('expected a number, variable, or parenthesised expression');
end

% postfix: [i], ., ->, ++, --, (call-through-pointer)
while token == 91 || token == 170 || token == 171 || token == 46 || ...
      token == 179 || token == 40
    if token == 91          % '[': index by the element size, then load
        t = etype;          % the base's type (the index parse changes etype)
        next();
        em('\tpushq\t%rax');      % save the base address
        parse_assignment();
        expect(93);
        if ~isempty(bstride)
            scale = bstride(1);
        elseif t >= 2
            scale = elem_size(t);
        else
            fail('pointer type expected for indexing');
        end
        if scale ~= 1
            em(sprintf('\timulq\t$%d, %%rax', scale));
        end
        em('\tmovq\t%rax, %rbx');
        em('\tpopq\t%rax');
        em('\taddq\t%rbx, %rax');     % the element address
        if ~isempty(bstride)
            if numel(bstride) > 1
                curarrsz = bstride(1);      % the row's byte size
                bstride = bstride(2:end);   % a row: address, no load
                etype = t;                  % the row decays to a pointer
            else
                bstride = [];
                curarrsz = 0;
                if t == 3
                    etype = 1;
                    em('\tmovzbl\t(%rax), %eax');
                    estruc = 0;
                elseif t - 2 >= 1000
                    etype = t - 2;
                    estruc = 1;
                elseif t - 2 == 7
                    etype = 7;
                    em('\tmovzwl\t(%rax), %eax');
                    estruc = 0;
                elseif t - 2 == 9
                    etype = 9;
                    em('\tmovl\t(%rax), %eax');
                    estruc = 0;
                elseif t - 2 == 6
                    etype = 6;
                    em('\tmovsd\t(%rax), %xmm0');
                    estruc = 0;
                else
                    etype = t - 2;
                    em('\tmovq\t(%rax), %rax');
                    estruc = 0;
                end
            end
        else
            et = t - 2;
            if t == 3
                etype = 1;                % char
                em('\tmovzbl\t(%rax), %eax');
                estruc = 0;
            elseif et >= 1000
                etype = et;               % struct element: address, no load
                estruc = 1;
            elseif et == 6
                etype = 6;
                em('\tmovsd\t(%rax), %xmm0');
                estruc = 0;
            else
                etype = et;
                if et == 7
                    em('\tmovzwl\t(%rax), %eax');
                elseif et == 9
                    em('\tmovl\t(%rax), %eax');
                elseif et == 1
                    em('\tmovzbl\t(%rax), %eax');
                else
                    em('\tmovq\t(%rax), %rax');
                end
                estruc = 0;
            end
        end
    elseif token == 40      % '(': call through a function pointer
        if ~is_fptr_type(etype) || estruc
            fail('call target is not a function pointer');
        end
        pret = fptr_rettype(etype);
        psret = is_sval(pret);
        next();
        em('\tpushq\t%rax');      % save the function pointer (deepest)
        if psret
            % struct-returning: reserve a slot, push a hidden pointer to it
            prsz = ssize_of(pret);
            em(sprintf('\tsubq\t$%d, %%rsp', prsz));
            em('\tmovq\t%rsp, %rax');
            em('\tpushq\t%rax');
        end
        nargs = 0;
        if token ~= 41
            while true
                parse_assignment();
                if estruc
                    % a struct-value arg: copy its full size
                    asz = ssize_of(etype);
                    em('\tmovq\t%rax, %rdx');
                    for kk = 1:asz/8
                        em('\tmovq\t(%rdx), %r8');
                        em('\tpushq\t%r8');
                        em('\taddq\t$8, %rdx');
                    end
                else
                    em('\tpushq\t%rax');
                end
                nargs = nargs + 1;
                if token == 44
                    next();
                else
                    break;
                end
            end
        end
        expect(41);
        if psret
            % [fptr][slot][slotptr][args]: the pointer is 8*nargs + 8 + rsz
            % above rsp
            em(sprintf('\tmovq\t%d(%%rsp), %%rax', 8 * nargs + 8 + prsz));
        elseif nargs > 0
            em(sprintf('\tmovq\t%d(%%rsp), %%rax', 8 * nargs));
        else
            em('\tmovq\t(%rsp), %rax');
        end
        em('\tcall\t*%rax');
        if psret
            % pop args, the slot pointer, the slot, and the saved pointer
            em(sprintf('\taddq\t$%d, %%rsp', 8 * nargs + 16 + prsz));
        else
            em(sprintf('\taddq\t$%d, %%rsp', 8 * (nargs + 1)));
        end
        etype = pret;
        estruc = psret;     % a struct result: the slot address, no load
    elseif token == 46 || token == 179    % '.' or '->': member access
        dot = (token == 46);
        next();
        if token ~= 150
            fail('expected a member name');
        end
        mname = idname;
        next();
        if dot
            if ~estruc
                fail('member access on a non-struct');
            end
            base_t = etype;
        else
            if estruc || etype < 1000
                fail('-> on a non-struct pointer');
            end
            base_t = etype - 2;       % the pointed-to struct value type
        end
        mem = member_lookup(base_t, mname);
        em(sprintf('\taddq\t$%d, %%rax', mem{1}));
        etype = mem{2};
        if etype >= 1000
            estruc = 1;               % a struct member: address, no load
        else
            estruc = 0;
            if etype == 1
                em('\tmovzbl\t(%rax), %eax');
            elseif etype == 6
                em('\tmovsd\t(%rax), %xmm0');
            else
                em('\tmovq\t(%rax), %rax');
            end
        end
    else                    % postfix ++/--
        op = token;
        next();
        if ~lvalue_addr()
            fail('bad lvalue for increment');
        end
        incdec(op, etype, 1);   % postfix: leave the old value
    end
end

% prefix operators, innermost (rightmost) first
for k = numel(ops):-1:1
    op = ops(k);
    if op == 45 && etype == 6     % '-' on a double: 0.0 - d in the
                                    % value domain (exact sign flip)
        em('\tmovabsq\t$0, %r15');
        em('\tcvtsi2sdq\t%r15, %xmm1');
        em('\tsubsd\t%xmm0, %xmm1');
        em('\tmovsd\t%xmm1, %xmm0');
    elseif op == 45             % '-' on an integer
        em('\tnegq\t%rax');
    elseif op == 126        % '~'
        em('\tnotq\t%rax');
    elseif op == 33 && etype == 6   % '!' on a double: (d == 0.0)
        em('\tmovabsq\t$0, %r15');
        em('\tcvtsi2sdq\t%r15, %xmm1');
        em('\tucomisd\t%xmm0, %xmm1');   % b=xmm1=0, a=d
        em('\tsete\t%al');
        em('\tmovzbl\t%al, %eax');
        etype = 0;
    elseif op == 33         % '!': logical not — eax = (eax == 0)
        em('\tcmpq\t$0, %rax');
        em('\tsete\t%al');
        em('\tmovzbl\t%al, %eax');
    elseif op == 38         % '&': address-of — drop the trailing load
        if ~lvalue_addr() && etype < 2
            fail('bad address of');
        end
        etype = etype + 2;
        estruc = 0;
    elseif op == 42         % '*': dereference — load through the pointer
        if is_fptr_type(etype)
            % a function pointer: *fp is the function designator (no load)
        elseif etype < 2
            fail('bad dereference');
        else
            etype = etype - 2;
            if etype == 3
                em('\tmovzbl\t(%rax), %eax');
                estruc = 0;
            elseif etype >= 1000
                estruc = 1;     % a struct value: no load
            elseif etype == 6
                em('\tmovsd\t(%rax), %xmm0');
                estruc = 0;
            else
                em('\tmovq\t(%rax), %rax');
                estruc = 0;
            end
        end
    elseif op == 170 || op == 171    % prefix ++/--
        if ~lvalue_addr()
            fail('bad lvalue for increment');
        end
        incdec(op, etype, 0);   % prefix: leave the new value
    end
    % unary '+' is a no-op
end
ltype = etype;   % for assignment store widths
end

function ok = lvalue_addr()
% lvalue_addr — if the expression ended with a load (variable/deref/index),
% drop it so eax holds the lvalue's address; a struct value / address is
% already in rax. Returns success.
global out
if numel(out) >= 1 && ...
   (strcmp(out{end}, sprintf('\tmovq\t(%%rax), %%rax')) || ...
    strcmp(out{end}, sprintf('\tmovzbl\t(%%rax), %%eax')) || ...
    strcmp(out{end}, sprintf('\tmovl\t(%%rax), %%eax')) || ...
    strcmp(out{end}, sprintf('\tmovzwl\t(%%rax), %%eax')) || ...
    strcmp(out{end}, sprintf('\tmovsd\t(%%rax), %%xmm0')))
    out(end) = [];
    ok = 1;
elseif numel(out) >= 1 && ~isempty(strfind(out{end}, 'leaq'))
    ok = 1;                 % a struct value or address: already in rax
elseif numel(out) >= 1 && ~isempty(strfind(out{end}, sprintf('\taddq\t%%rbx, %%rax')))
    ok = 1;                 % an indexed row: its address is already in rax
else
    ok = 0;
end
end

function incdec(op, t, post)
% incdec — ++/-- on the lvalue whose address is in rax, type t. Scale is
% the element size (1 for scalars/char*, the struct size for struct
% pointers, 8 otherwise). post=1 leaves the OLD value in rax; post=0 the NEW.
global out
scale = 1;
if t >= 2 && t ~= 3
    scale = elem_size(t);
end
em('\tpushq\t%rax');            % save the address
if t == 1
    em('\tmovzbl\t(%rax), %eax');
elseif t == 6
    em('\tmovsd\t(%rax), %xmm0');
else
    em('\tmovq\t(%rax), %rax');
end
if post
    if t == 6
        em('\tmovsd\t%xmm0, %xmm2');   % old value
    else
        em('\tmovq\t%rax, %rbx');   % old value
    end
end
if t == 6
    em('\tmovabsq\t$0x3FF0000000000000, %rbx');
    em('\tcvtsi2sdq\t%rbx, %xmm1');   % 1.0
    if op == 170
        em('\taddsd\t%xmm1, %xmm0');
    else
        em('\tsubsd\t%xmm1, %xmm0');
    end
elseif op == 170
    em(sprintf('\taddq\t$%d, %%rax', scale));
else
    em(sprintf('\tsubq\t$%d, %%rax', scale));
end
if post
    em('\tpopq\t%rcx');         % the address
    if t == 1
        em('\tmovb\t%al, (%rcx)');
    elseif t == 6
        em('\tmovsd\t%xmm0, (%rcx)');
    else
        em('\tmovq\t%rax, (%rcx)');
    end
    if t == 6
        em('\tmovsd\t%xmm2, %xmm0');   % old value
    else
        em('\tmovq\t%rbx, %rax');
    end
else
    em('\tpopq\t%rbx');         % the address
    if t == 1
        em('\tmovb\t%al, (%rbx)');
    elseif t == 6
        em('\tmovsd\t%xmm0, (%rbx)');
    else
        em('\tmovq\t%rax, (%rbx)');
    end
end
end


function b = cc_d2bits(d)
% cc_d2bits — the IEEE-754 double d as an int64 bit pattern.  Exact
% integer arithmetic only (no typecast: the clone's typecast can corrupt
% bit patterns in local-function contexts).
if isnan(d)
    b = bitor(int64(9218868437227405312), int64(2251799813685248)); % +NaN
    return;
elseif isinf(d)
    b = int64(9218868437227405312);   % +Inf
    if d < 0
        b = bitor(b, bitshift(int64(1), 63));
    end
    return;
elseif d == 0
    if 1 / d < 0
        b = bitshift(int64(1), 63);   % -0.0
    else
        b = int64(0);
    end
    return;
end
negbit = int64(0);
if d < 0
    negbit = bitshift(int64(1), 63);
    d = -d;
end
e = floor(log2(d));   % d<1 needs floor (fix truncates toward 0)
if e < -1022
    mant = int64(d / 2^-1074);        % subnormal
    expo = int64(0);
else
    f = d / 2^e;
    mant = int64(round((f - 1) * 2^52));
    expo = int64(e) + int64(1023);
end
b = bitor(negbit, bitor(bitshift(expo, 52), mant));
end


