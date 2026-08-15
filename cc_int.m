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
%   Types: 0=int, 1=char, 2=int*, 3=char*, 4=int**, … (base + 2*ptr depth;
%   only t==1 is a byte; a pointer's element size is 1 iff t==3).
%
% Emits COFF assembly for MSYS2 binutils on Windows (see README for the
% gcc invocation). Pipeline: tokenizer (next) → recursive-descent parser
% (parse_program/parse_expr/…) → codegen.
%
%   cc_int('in.c', 'out.s')
%   gcc out.s -o out
%   .\out.exe  (cmd)  /  ./out  (bash) — exit code is the returned value

global src si token token_val idname strtext out fname lbl lvars lvartype ...
       lvararr fbytes funcs fret called retlbl cfn globals gtype garr glist ...
       strs nstr etype ltype cret loopctx

if nargin ~= 2
   error('USAGE: cc_int in.c out.s');
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
strtext = '';   % text of the last string literal
lbl = 0;      % unique-label counter for short-circuit jumps
cfn = 0;      % function counter (.LFBn/.LFEn/.Lretn)
loopctx = {};   % stack of {break_label, continue_label} for break/continue
lvars = struct();    % local/param name -> frame offset (bytes)
lvartype = struct(); % local/param name -> type code (0 int, 1 char, 2 int* …)
lvararr = struct();  % local name -> 1 if an array (name decays to a pointer)
fbytes = 0;          % current function's frame bytes (locals only)
funcs = struct();    % defined function name -> param count
fret = struct();     % function name -> return type code
called = struct();   % called function names (verified defined at the end)
retlbl = '';         % current function's return label
cret = 0;            % current function returns char
etype = 0;           % type code of the current expression
ltype = 0;           % type of the last parsed lvalue (store width)
globals = struct();  % defined global names
gtype = struct();    % global name -> type code
garr = struct();     % global name -> 1 if an array
glist = {};          % {name, type, init or []} for the .comm/.data output
strs = {};           % {label, text} string literals for the .data output
nstr = 0;            % string-literal counter
out = {};       % emitted assembly lines (cell; tabs are literal in em)

next();
parse_program();

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
global src si token token_val idname strtext
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
    v = int64(0);
    while si <= numel(src) && src(si) >= '0' && src(si) <= '9'
        v = v * int64(10) + int64(double(src(si)) - 48);
        si = si + 1;
    end
    token = 128;                % Num
    token_val = v;
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
    else
        token = 150;            % Id (incl. 'main'); text in idname
        idname = id;
    end
    return;
elseif c == 34                  % '"': string literal
    si = si + 1;
    strtext = '';
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
        strtext = [strtext, v];
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
global token out fname funcs called glist
em(sprintf('\t.file\t"%s"', fname));
em('\t.text');
while token ~= 0
    parse_decl_or_func();
end
names = fieldnames(called);
for k = 1:numel(names)
    if ~isfield(funcs, names{k})
        fail(sprintf('call to undefined function %s', names{k}));
    end
end
if ~isfield(funcs, 'main')
    fail('no main function');
end
emit_globals();
end

function parse_decl_or_func()
% type ('*')* name — '(' means a function definition, otherwise globals
global token idname
if token == 131             % int
    base = 0;
    next();
elseif token == 134         % char
    base = 1;
    next();
else
    fail('expected int or char declaration');
end
depth = 0;
while token == 42           % '*'
    depth = depth + 1;
    next();
end
if token ~= 150
    fail('expected a name');
end
name = idname;
next();
if token == 40              % '(': function
    if depth > 0
        fail('pointer-returning functions are not supported');
    end
    parse_function_tail(name, base);
else
    parse_globals(name, base, depth);
end
end

function parse_function_tail(fname2, ischarfn)
% after 'type name': '(' params ')' '{' <statements> return '}' — emit the
% per-function prologue, backpatch the frame size, and the epilogue.
global token out idname lvars lvartype lvararr fbytes funcs fret retlbl cfn cret
expect(40);                 % (
save_lvars = lvars;
save_lvartype = lvartype;
save_lvararr = lvararr;
save_fbytes = fbytes;
lvars = struct();
lvartype = struct();
lvararr = struct();
fbytes = 0;
nparams = parse_params();
expect(41);                 % )
expect(123);                % {
if isfield(funcs, fname2)
    fail(sprintf('duplicate function %s', fname2));
end
funcs.(fname2) = nparams;   % register before the body (recursion)
fret.(fname2) = ischarfn;   % return type for call sites
cret = ischarfn;
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
frame_idx = em('\tsubq\t$0, %rsp');   % local frame; size backpatched

parse_body();
frame_sz = 16 * ceil(fbytes / 16);
out{frame_idx} = sprintf('\tsubq\t$%d, %%rsp', frame_sz);

expect(125);                % }
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
fbytes = save_fbytes;
end

function parse_globals(name, base, depth)
% global: name (('[' Num ']') | ('=' const|string)?) (',' name …)? ';' —
% collected for the .comm/.data section emitted at the end of the file.
global token idname strtext globals gtype garr glist
while true
    if isfield(globals, name)
        fail(sprintf('duplicate global %s', name));
    end
    globals.(name) = 1;
    t = base + 2 * depth;
    isarr = 0;
    asz = 0;
    if token == 91          % '[': array
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
        isarr = 1;
    end
    gtype.(name) = t + 2 * isarr;
    garr.(name) = isarr;
    initv = [];
    if token == 61          % '=': constant initializer
        next();
        if token == 172     % string literal: pointer init
            initv = ['S', strtext];
            next();
        else
            neg = 0;
            if token == 45      % '-'
                neg = 1;
                next();
            end
            if token ~= 128
                fail('expected a constant global initializer');
            end
            initv = double(token_val);
            next();
            if neg
                initv = -initv;
            end
        end
    end
    glist{end+1} = {name, gtype.(name), isarr, asz, initv};
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
    asz = g{4};
    v = g{5};
    if isarr
        if mod(t, 2) == 1       % char-based element
            nbytes = asz;
        else
            nbytes = 4 * asz;
        end
    elseif t == 1
        nbytes = 1;
    else
        nbytes = 4;
    end
    if isempty(v)
        em(sprintf('\t.comm\t%s,%d,%d', nm, nbytes, nbytes));
    else
        if ~dat
            em('\t.data');
            dat = 1;
        end
        em(sprintf('\t.globl\t%s', nm));
        em(sprintf('%s:', nm));
        if ischar(v)
            % string-literal pointer initializer (marker 'S' + text)
            em(sprintf('\t.quad\t%s', new_str(v(2:end))));
        elseif t == 1
            em(sprintf('\t.byte\t%d', v));
        else
            em(sprintf('\t.quad\t%d', v));
        end
    end
end
em('\t.data');
for k = 1:numel(strs)
    s = strs{k};
    em(sprintf('%s:', s{1}));
    txt = s{2};
    txt = strrep(txt, '\', '\\');
    txt = strrep(txt, '"', '\"');
    txt = strrep(txt, char(10), '\n');
    em(sprintf('\t.string\t"%s"', txt));
end
end

function lab = new_str(text)
% new_str — register a string literal, return its label (emitted later).
global strs nstr
lab = sprintf('.Lstr%d', nstr);
nstr = nstr + 1;
strs{end+1} = {lab, text};
end

function parse_body()
% parse_body — main's body: statements until the final top-level `return`
% (mirrors the tutorial — main must end with a return).
global token
while token ~= 130          % return
    parse_statement();
end
parse_return_statement();
end

function nparams = parse_params()
% params := (int|char ('*')* name (('[' … ']')? (',' …)*))? — collect
% names/types first, then assign rbp offsets: with args pushed
% left-to-right, param k (1-based) sits at 8*(nparams-k+2)(%%rbp). Array
% params decay to pointers.
global token idname lvars lvartype lvararr
nparams = 0;
names = {};
types = {};
while token ~= 41           % ')'
    if token == 131         % int
        base = 0;
        next();
    elseif token == 134     % char
        base = 1;
        next();
    else
        fail('expected a parameter declaration');
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
    if token == 91          % '[': array parameter decays to a pointer
        while token == 91
            next();
            if token == 128
                next();
            end
            expect(93);
        end
        t = t + 2;
    end
    types{end+1} = t;
    if token == 44          % ','
        next();
    elseif token ~= 41
        fail('expected , or ) in the parameter list');
    end
end
nparams = numel(names);
for k = 1:nparams
    nm = names{k};
    if isfield(lvars, nm)
        fail(sprintf('duplicate parameter %s', nm));
    end
    lvars.(nm) = 8 * (nparams - k + 2);
    lvartype.(nm) = types{k};
    lvararr.(nm) = 0;   % params are pointers, not arrays
end
end

function parse_statement()
% statement := declaration | '{' statement* '}' | if | while | for | do |
% break | continue | return | expr ';'
global token
if token == 131 || token == 134    % int/char: declaration
    parse_declaration();
elseif token == 123         % '{': block
    next();
    while token ~= 125      % '}'
        parse_statement();
    end
    next();
elseif token == 151         % if
    parse_if();
elseif token == 152         % while
    parse_while();
elseif token == 173         % for
    parse_for();
elseif token == 174         % do
    parse_do();
elseif token == 175         % break
    parse_break();
elseif token == 176         % continue
    parse_continue();
elseif token == 130         % return (nested in a block)
    parse_return_statement();
else
    parse_expression_statement();
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
global token loopctx out
next();                     % consume 'for'
expect(40);
if token ~= 59              % ';': optional init
    parse_assignment();
end
expect(59);
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
% return := 'return' expr ';' — value in eax (zero-extended for char
% functions), jump to the function's epilogue label.
global retlbl cret
expect(130);
parse_expr();
expect(59);
if cret
    em('\tmovzbl\t%al, %eax');
end
em(sprintf('\tjmp\t%s', retlbl));
end

function parse_declaration()
% declaration := type ('*')* name (('[' size ']')? (',' …)*) ('=' expr)? ';'
% — int/pointer 8 frame bytes, char 1, arrays n*elem; the initializer is
% stored directly (byte for char).
global token idname lvars lvartype lvararr fbytes
if token == 131             % int
    base = 0;
    next();
elseif token == 134         % char
    base = 1;
    next();
else
    fail('expected a local declaration');
end
while true
    depth = 0;
    while token == 42       % '*'
        depth = depth + 1;
        next();
    end
    if token ~= 150
        fail('expected a variable name');
    end
    name = idname;
    next();
    if isfield(lvars, name)
        fail(sprintf('duplicate local %s', name));
    end
    t = base + 2 * depth;
    isarr = 0;
    asz = 0;
    if token == 91          % '[': array
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
        isarr = 1;
    end
    if isarr
        if base == 1
            nbytes = asz;       % char array: 1 byte per element
        else
            nbytes = 8 * asz;
        end
        lvartype.(name) = t + 2;   % the name decays to a pointer
        lvararr.(name) = 1;
    else
        if t == 1
            nbytes = 1;
        else
            nbytes = 8;
        end
        lvartype.(name) = t;
        lvararr.(name) = 0;
    end
    off = -(fbytes + nbytes);
    fbytes = fbytes + nbytes;
    lvars.(name) = off;
    if token == 61          % '=': initializer
        next();
        parse_assignment();
        if t == 1
            em(sprintf('\tmovb\t%%al, %d(%%rbp)', off));
        else
            em(sprintf('\tmovq\t%%rax, %d(%%rbp)', off));
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
parse_assignment();
expect(59);
end

function parse_expr()
% expression := conditional
parse_conditional();
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
    if token == 58          % ':'
        next();
    else
        fail('missing colon in conditional');
    end
    em(sprintf('\tjmp\t%s', e));
    em(sprintf('%s:', f));
    parse_conditional();
    em(sprintf('%s:', e));
    etype = 0;
end
end

function parse_assignment()
% assignment := conditional (assign-op assignment)* — right-associative.
% The LHS must be an lvalue (its load is dropped, leaving the address);
% the address is pushed, the RHS evaluated, then stored, so the value (in
% eax) is the RHS — `y = x = 5` chains work. Compound ops load-modify-store
% and scale by the element size for pointer `+=`/`-=`.
global token out ltype etype
parse_conditional();
while token == 61 || (token >= 160 && token <= 169)
    op = token;
    sav_ltype = ltype;      % the LHS's type (RHS parsing may change ltype)
    if ~lvalue_addr()
        fail('bad lvalue in assignment');
    end
    if op == 61             % plain '='
        em('\tpushq\t%rax');
        next();
        parse_assignment();
        em('\tpopq\t%rbx');
        if sav_ltype == 1
            em('\tmovb\t%al, (%rbx)');
        else
            em('\tmovq\t%rax, (%rbx)');
        end
    else
        % compound: load-modify-store through the address
        em('\tpushq\t%rax');            % save the address
        if sav_ltype == 1
            em('\tmovzbl\t(%rax), %eax');
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
            else
                em('\tsarq\t%cl, %rax');
            end
        else
            em('\tmovq\t%rax, %rbx');   % rhs
            if (op == 160 || op == 161) && sav_ltype >= 2 && sav_ltype ~= 3
                em('\timulq\t$8, %rbx');   % pointer +=/-=: scale by elem
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

function expect_id(name)
% expect_id — consume the current identifier if its text is `name`.
global token idname
if token == 150 && strcmp(idname, name)
    next();
else
    fail(sprintf('expected identifier %s', name));
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
    em('\tpushq\t%rax');
    parse_relational();
    em('\tmovq\t%rax, %rbx');
    em('\tpopq\t%rax');
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

function parse_relational()
% relational := shift (('<' | '>' | '<=' | '>=') shift)* — signed
% comparisons; eax = left, ebx = right, so setl/setg/etc. read eax-ebx.
global token etype
parse_shift();
while token == 144 || token == 145 || token == 146 || token == 147  % Lt Gt Le Ge
    op = token;
    next();
    em('\tpushq\t%rax');
    parse_shift();
    em('\tmovq\t%rax, %rbx');
    em('\tpopq\t%rax');
    em('\tcmpq\t%rbx, %rax');
    if op == 144        % Lt
        em('\tsetl\t%al');
    elseif op == 145    % Gt
        em('\tsetg\t%al');
    elseif op == 146    % Le
        em('\tsetle\t%al');
    else                % Ge
        em('\tsetge\t%al');
    end
    em('\tmovzbl\t%al, %eax');
    etype = 0;
end
end

function parse_shift()
% shift := additive (('<<' | '>>') additive)* — left-associative; the shift
% count goes in %cl; '>>' is an arithmetic shift (signed int).
global token etype
parse_additive();
while token == 140 || token == 141   % Shl Shr
    op = token;
    next();
    em('\tpushq\t%rax');        % save the left operand
    parse_additive();
    em('\tmovq\t%rax, %rcx');   % shift count in %cl
    em('\tpopq\t%rax');
    if op == 140
        em('\tshlq\t%cl, %rax');
    else
        em('\tsarq\t%cl, %rax');
    end
    etype = 0;
end
end

function parse_additive()
% additive := term (('+' | '-') term)* — pointer operands scale the
% integer by the element size (1 for char*, 4 otherwise); ptr - ptr gives
% the element difference.
global token etype
parse_term();
while token == 43 || token == 45   % '+' '-'
    op = token;
    t = etype;              % the left operand's type
    next();
    em('\tpushq\t%rax');
    parse_term();
    rhs_t = etype;
    em('\tmovq\t%rax, %rbx');
    em('\tpopq\t%rax');
    if t >= 2               % the left is a pointer
        if op == 45 && rhs_t >= 2
            % ptr - ptr: byte difference / element size
            em('\tsubq\t%rbx, %rax');
            if t ~= 3
                em('\tmovq\t$8, %rcx');
                em('\tcqto');
                em('\tidivq\t%rcx');
            end
            etype = 0;
        else
            if t ~= 3       % char*: element size 1 — no scaling
                em('\timulq\t$8, %rbx');
            end
            if op == 43
                em('\taddq\t%rbx, %rax');
            else
                em('\tsubq\t%rbx, %rax');
            end
            etype = t;      % still a pointer
        end
    else
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
% term := unary (('*' | '/' | '%') unary)* — left-associative. '/' and '%'
% use cqto/idivq: the 64-bit signed quotient is in eax, remainder in edx
% (C semantics: truncation toward zero, remainder takes the dividend's
% sign).
global token
parse_unary();
while token == 42 || token == 47 || token == 37   % '*' '/' '%'
    op = token;
    next();
    em('\tpushq\t%rax');
    parse_unary();
    em('\tmovq\t%rax, %rbx');
    em('\tpopq\t%rax');
    if op == 42
        em('\timulq\t%rbx, %rax');
    else
        em('\tcqto');
        em('\tidivq\t%rbx');
        if op == 37
            em('\tmovq\t%rdx, %rax');
        end
    end
    etype = 0;
end
end

function parse_unary()
% unary := prefix* primary postfix*; primary := Num | Str | Id | '(' expr ')'
% postfix := '[' expr ']' | '++' | '--'. Prefix ops apply in reverse.
% Types: etype tracks the current expression type; arrays decay (no load).
global token token_val idname strtext lvars lvartype lvararr globals gtype ...
       funcs fret called ltype etype
ops = [];
while token == 45 || token == 126 || token == 33 || token == 43 || ...   % - ~ ! +
      token == 38 || token == 42 || token == 170 || token == 171          % & * ++ --
    ops = [ops, token];
    next();
end
if token == 40              % '(': parenthesised expression (may assign)
    next();
    parse_assignment();
    expect(41);
elseif token == 128         % Num
    em(sprintf('\tmovq\t$%d, %%rax', double(token_val)));
    etype = 0;
    next();
elseif token == 172         % Str: string literal -> char* to .Lstr data
    lab = new_str(strtext);
    em(sprintf('\tleaq\t%s(%%rip), %%rax', lab));
    etype = 3;              % char*
    next();
elseif token == 150         % Id: function call or variable
    name = idname;
    next();
    if token == 40          % '(': function call
        next();
        nargs = 0;
        if token ~= 41      % ')'
            while true
                parse_assignment();
                em('\tpushq\t%rax');
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
        called.(name) = 1;
        em(sprintf('\tcall\t%s', name));
        if nargs > 0
            em(sprintf('\taddq\t$%d, %%rsp', 8 * nargs));
        end
        if isfield(fret, name)
            etype = fret.(name);
        else
            etype = 0;
        end
    else
        % variable: local/param (rbp) or global (rip); arrays skip the load
        if isfield(lvars, name)
            t = lvartype.(name);
            isarr = lvararr.(name);
            em(sprintf('\tleaq\t%d(%%rbp), %%rax', lvars.(name)));
        elseif isfield(globals, name)
            t = gtype.(name);
            isarr = garr.(name);
            em(sprintf('\tleaq\t%s(%%rip), %%rax', name));
        else
            fail(sprintf('undefined variable %s', name));
        end
        etype = t;
        if ~isarr
            if t == 1
                em('\tmovzbl\t(%rax), %eax');
            else
                em('\tmovq\t(%rax), %rax');
            end
        end
    end
else
    fail('expected a number, variable, or parenthesised expression');
end

% postfix: [i], ++, --
while token == 91 || token == 170 || token == 171
    if token == 91          % '[': index by the element size, then load
        t = etype;          % the base's type (the index parse changes etype)
        next();
        em('\tpushq\t%rax');      % save the base address
        parse_assignment();
        expect(93);
        if t >= 2
            if t ~= 3       % char*: element size 1
                em('\timulq\t$8, %rax');
            end
            em('\tmovq\t%rax, %rbx');
        else
            fail('pointer type expected for indexing');
        end
        em('\tpopq\t%rax');
        em('\taddq\t%rbx, %rax');     % the element address
        if t == 3
            etype = 1;                % char
            em('\tmovzbl\t(%rax), %eax');
        else
            etype = t - 2;
            em('\tmovq\t(%rax), %rax');
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
    if op == 45             % '-'
        em('\tnegq\t%rax');
    elseif op == 126        % '~'
        em('\tnotq\t%rax');
    elseif op == 33         % '!': logical not — eax = (eax == 0)
        em('\tcmpq\t$0, %rax');
        em('\tsete\t%al');
        em('\tmovzbl\t%al, %eax');
    elseif op == 38         % '&': address-of — drop the trailing load
        if ~lvalue_addr() && etype < 2
            fail('bad address of');
        end
        etype = etype + 2;
    elseif op == 42         % '*': dereference — load through the pointer
        if etype < 2
            fail('bad dereference');
        end
        if etype == 3
            em('\tmovzbl\t(%rax), %eax');
        else
            em('\tmovq\t(%rax), %rax');
        end
        etype = etype - 2;
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
% drop it so eax holds the lvalue's address. Returns success.
global out
if numel(out) >= 1 && ...
   (strcmp(out{end}, sprintf('\tmovq\t(%%rax), %%rax')) || ...
    strcmp(out{end}, sprintf('\tmovzbl\t(%%rax), %%eax')))
    out(end) = [];
    ok = 1;
else
    ok = 0;
end
end

function incdec(op, t, post)
% incdec — ++/-- on the lvalue whose address is in eax, type t. Scale is
% 1 for scalars/char*, 4 for other pointers. post=1 leaves the OLD value
% in eax; post=0 leaves the NEW value.
global out
scale = 1;
if t >= 2 && t ~= 3
    scale = 8;
end
em('\tpushq\t%rax');            % save the address
if t == 1
    em('\tmovzbl\t(%rax), %eax');
else
    em('\tmovq\t(%rax), %rax');
end
if post
    em('\tmovq\t%rax, %rbx');   % old value = the postfix result
end
if op == 170
    em(sprintf('\taddq\t$%d, %%rax', scale));
else
    em(sprintf('\tsubq\t$%d, %%rax', scale));
end
if post
    em('\tpopq\t%rcx');         % the address
    if t == 1
        em('\tmovb\t%al, (%rcx)');
    else
        em('\tmovq\t%rax, (%rcx)');
    end
    em('\tmovq\t%rbx, %rax');   % restore the old value
else
    em('\tpopq\t%rbx');         % the address
    if t == 1
        em('\tmovb\t%al, (%rbx)');
    else
        em('\tmovq\t%rax, (%rbx)');
    end
end
end
