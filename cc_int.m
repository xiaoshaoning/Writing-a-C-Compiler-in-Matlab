function cc_int(varargin)
% cc_int — x86-64 assembly compiler (Norasandler "Writing a C Compiler").
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
%           the dividend's sign (cltd/idivl).
%   Part 7: statements and variables — `int x;`, `int x = 5;` (comma
%           lists), local stack frame (subq after the prologue, backpatched
%           size), expression statements, assignment (right-associative,
%           address-based so `y = x = 5` chains), locals as primaries.
%   Part 8: control flow — `if`/`else`, `while`, blocks, and `return`
%           anywhere (jumps to a .Lmain_ret epilogue label).
%
% Emits COFF assembly for MSYS2 binutils on Windows (see README for the
% gcc invocation). Pipeline: tokenizer (next) → recursive-descent parser
% (parse_program/parse_expr/…) → codegen.
%
%   cc_int('in.c', 'out.s')
%   gcc out.s -o out
%   .\out.exe  (cmd)  /  ./out  (bash) — exit code is the returned value

global src si token token_val idname out fname lbl lvars nlocals

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
lbl = 0;      % unique-label counter for short-circuit jumps
lvars = struct();   % local-variable name -> frame offset (bytes)
nlocals = 0;        % number of local ints declared in main
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
% next — tokenizer. Num=128, Return=130, Int=131, Id=150, Shl=140,
% Shr=141, Lan=142, Lor=143, Lt=144, Gt=145, Le=146, Ge=147, Eq=148,
% Ne=149, Assign=61 ('='); single-char operators/braces keep their ASCII
% code; 0 = EOF. Skips whitespace. Identifier text goes into idname.
global src si token token_val idname
while si <= numel(src)
    c = src(si);
    if c == ' ' || c == char(9) || c == char(10) || c == char(13)
        si = si + 1;
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
    elseif strcmp(id, 'if')
        token = 151;            % If
    elseif strcmp(id, 'while')
        token = 152;            % While
    elseif strcmp(id, 'else')
        token = 153;            % Else
    else
        token = 150;            % Id (incl. 'main'); text in idname
        idname = id;
    end
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
        token = 140;            % Shl
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
        token = 141;            % Shr
    else
        token = 145;            % Gt
    end
    return;
elseif c == '&'
    si = si + 1;
    if si <= numel(src) && src(si) == '&'
        si = si + 1;
        token = 142;            % Lan
    else
        token = 38;             % '&'
    end
    return;
elseif c == '|'
    si = si + 1;
    if si <= numel(src) && src(si) == '|'
        si = si + 1;
        token = 143;            % Lor
    else
        token = 124;            % '|'
    end
    return;
else
    token = double(c);
    si = si + 1;
    return;
end
end

function parse_program()
% parse_program — int main() { <statements> return <expr>; } — emit the .s
% template around the parsed body, with a backpatched local-frame subq.
global token out fname lvars nlocals
em(sprintf('\t.file\t"%s"', fname));
em('\t.text');
em('\t.globl\tmain');
% Windows/MSYS2 binutils: ELF-style ".type main, @function" is rejected —
% '@' starts a comment in COFF GAS. gcc emits .def/.scl/.type/.endef.
em('\t.def\tmain;\t.scl\t2;\t.type\t32;\t.endef');
em('main:');
em('.LFB0:');
em('\t.cfi_startproc');
em('\tpushq\t%rbp');
em('\t.cfi_def_cfa_offset 16');
em('\t.cfi_offset 6, -16');
em('\tmovq\t%rsp, %rbp');
em('\t.cfi_def_cfa_register 6');
frame_idx = em('\tsubq\t$0, %rsp');   % local frame; size backpatched

expect(131);        % int
expect_id('main');
expect(40);         % (
expect(41);         % )
expect(123);        % {

% Backpatch the frame size once the locals are counted (parse_body ends
% after the return statement). Round up to a multiple of 16 (%rsp stays
% 16-aligned for the runtime's benefit).
parse_body();
frame_sz = 16 * ceil(4 * nlocals / 16);
out{frame_idx} = sprintf('\tsubq\t$%d, %%rsp', frame_sz);

expect(125);    % }
if token ~= 0
    fail('trailing tokens after the main body');
end

em('.Lmain_ret:');          % target of every `return`
em('\tmovq\t%rbp, %rsp');   % discard the local frame
em('\tpopq\t%rbp');
em('\t.cfi_def_cfa 7, 8');
em('\tret');
em('\t.cfi_endproc');
em('.LFE0:');
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

function parse_statement()
% statement := declaration | '{' statement* '}' | if | while | return | expr ';'
global token
if token == 131             % int: declaration
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
em('\tcmpl\t$0, %eax');
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
% while := 'while' '(' expr ')' statement — start: / <cond> / je end /
% <body> / jmp start / end:
global token
next();                     % consume 'while'
s = newlabel();
e = newlabel();
em(sprintf('%s:', s));
expect(40);
parse_expr();
expect(41);
em('\tcmpl\t$0, %eax');
em(sprintf('\tje\t%s', e));
parse_statement();
em(sprintf('\tjmp\t%s', s));
em(sprintf('%s:', e));
end

function parse_return_statement()
% return := 'return' expr ';' — value in eax, jump to the epilogue.
expect(130);
parse_expr();
expect(59);
em('\tjmp\t.Lmain_ret');
end

function parse_declaration()
% declaration := 'int' name (',' name)* ('=' expression)? ';' — each name
% gets a 4-byte frame slot; the initializer is stored directly.
global token idname lvars nlocals
while true
    expect(131);            % int
    while true
        if token ~= 150
            fail('expected a variable name');
        end
        name = idname;
        next();
        if isfield(lvars, name)
            fail(sprintf('duplicate local %s', name));
        end
        nlocals = nlocals + 1;
        off = 4 * nlocals;
        lvars.(name) = off;
        if token == 61      % '=': initializer
            next();
            parse_assignment();
            em(sprintf('\tmovl\t%%eax, -%d(%%rbp)', off));
        end
        if token == 44      % ','
            next();
        else
            break;
        end
    end
    expect(59);             % ;
    if token == 131         % int: another declaration
        continue;
    end
    return;
end
end

function parse_expression_statement()
% expression_statement := expression ';' — the value is discarded.
parse_assignment();
expect(59);
end

function parse_expr()
% expression := assignment
parse_assignment();
end

function parse_assignment()
% assignment := logical_or ('=' assignment)* — right-associative. The LHS
% must be an lvalue (a local whose load can be dropped, leaving its
% address); the address is pushed, the RHS evaluated, then stored, so the
% assignment's value (in eax) is the RHS — `y = x = 5` chains work.
global token out
parse_logical_or();
while token == 61           % '='
    if numel(out) >= 1 && strcmp(out{end}, sprintf('\tmovl\t(%%rax), %%eax'))
        out(end) = [];      % drop the load; eax = the local's address
    else
        fail('bad lvalue in assignment');
    end
    em('\tpushq\t%rax');
    next();
    parse_assignment();
    em('\tpopq\t%rbx');
    em('\tmovl\t%eax, (%rbx)');
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
global token
parse_logical_and();
while token == 143           % Lor
    next();
    t = newlabel();
    e = newlabel();
    em('\tcmpl\t$0, %eax');
    em(sprintf('\tjne\t%s', t));
    parse_logical_and();
    em('\tcmpl\t$0, %eax');
    em(sprintf('\tjne\t%s', t));
    em('\tmovl\t$0, %eax');
    em(sprintf('\tjmp\t%s', e));
    em(sprintf('%s:', t));
    em('\tmovl\t$1, %eax');
    em(sprintf('%s:', e));
end
end

function parse_logical_and()
% logical_and := bitwise_or ('&&' bitwise_or)* — short-circuit: a zero
% operand jumps straight to set-the-result-to-0.
global token
parse_bit_or();
while token == 142           % Lan
    next();
    f = newlabel();
    e = newlabel();
    em('\tcmpl\t$0, %eax');
    em(sprintf('\tje\t%s', f));
    parse_bit_or();
    em('\tcmpl\t$0, %eax');
    em(sprintf('\tje\t%s', f));
    em('\tmovl\t$1, %eax');
    em(sprintf('\tjmp\t%s', e));
    em(sprintf('%s:', f));
    em('\tmovl\t$0, %eax');
    em(sprintf('%s:', e));
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
global token
parse_bit_xor();
while token == 124          % '|'
    next();
    em('\tpushq\t%rax');    % save the left operand
    parse_bit_xor();
    em('\tmovl\t%eax, %ebx');
    em('\tpopq\t%rax');
    em('\torl\t%ebx, %eax');
end
end

function parse_bit_xor()
% bitwise_xor := bitwise_and ('^' bitwise_and)*
global token
parse_bit_and();
while token == 94           % '^'
    next();
    em('\tpushq\t%rax');
    parse_bit_and();
    em('\tmovl\t%eax, %ebx');
    em('\tpopq\t%rax');
    em('\txorl\t%ebx, %eax');
end
end

function parse_bit_and()
% bitwise_and := equality ('&' equality)*
global token
parse_equality();
while token == 38           % '&'
    next();
    em('\tpushq\t%rax');
    parse_equality();
    em('\tmovl\t%eax, %ebx');
    em('\tpopq\t%rax');
    em('\tandl\t%ebx, %eax');
end
end

function parse_equality()
% equality := relational (('==' | '!=') relational)* — result 0/1 via setcc
global token
parse_relational();
while token == 148 || token == 149   % Eq Ne
    op = token;
    next();
    em('\tpushq\t%rax');
    parse_relational();
    em('\tmovl\t%eax, %ebx');
    em('\tpopq\t%rax');
    em('\tcmpl\t%ebx, %eax');
    if op == 148
        em('\tsete\t%al');
    else
        em('\tsetne\t%al');
    end
    em('\tmovzbl\t%al, %eax');
end
end

function parse_relational()
% relational := shift (('<' | '>' | '<=' | '>=') shift)* — signed
% comparisons; eax = left, ebx = right, so setl/setg/etc. read eax-ebx.
global token
parse_shift();
while token == 144 || token == 145 || token == 146 || token == 147  % Lt Gt Le Ge
    op = token;
    next();
    em('\tpushq\t%rax');
    parse_shift();
    em('\tmovl\t%eax, %ebx');
    em('\tpopq\t%rax');
    em('\tcmpl\t%ebx, %eax');
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
end
end

function parse_shift()
% shift := additive (('<<' | '>>') additive)* — left-associative; the shift
% count goes in %cl; '>>' is an arithmetic shift (signed int).
global token
parse_additive();
while token == 140 || token == 141   % Shl Shr
    op = token;
    next();
    em('\tpushq\t%rax');        % save the left operand
    parse_additive();
    em('\tmovl\t%eax, %ecx');   % shift count in %cl
    em('\tpopq\t%rax');
    if op == 140
        em('\tshll\t%cl, %eax');
    else
        em('\tsarl\t%cl, %eax');
    end
end
end

function parse_additive()
% additive := term (('+' | '-') term)* — left-associative.
global token
parse_term();
while token == 43 || token == 45   % '+' '-'
    op = token;
    next();
    em('\tpushq\t%rax');
    parse_term();
    em('\tmovl\t%eax, %ebx');
    em('\tpopq\t%rax');
    if op == 43
        em('\taddl\t%ebx, %eax');
    else
        em('\tsubl\t%ebx, %eax');
    end
end
end

function parse_term()
% term := unary (('*' | '/' | '%') unary)* — left-associative. '/' and '%'
% use cltd/idivl: the 64-bit signed quotient is in eax, remainder in edx
% (C semantics: truncation toward zero, remainder takes the dividend's
% sign).
global token
parse_unary();
while token == 42 || token == 47 || token == 37   % '*' '/' '%'
    op = token;
    next();
    em('\tpushq\t%rax');
    parse_unary();
    em('\tmovl\t%eax, %ebx');
    em('\tpopq\t%rax');
    if op == 42
        em('\timull\t%ebx, %eax');
    else
        em('\tcltd');
        em('\tidivl\t%ebx');
        if op == 37
            em('\tmovl\t%edx, %eax');
        end
    end
end
end

function parse_unary()
% unary := ('-' | '~' | '!' | '+')* primary; primary := Num | Id | '(' expr
% ')' — a local variable loads from its frame slot (leaq + movl).
global token token_val idname lvars
ops = [];
while token == 45 || token == 126 || token == 33 || token == 43   % - ~ ! +
    ops = [ops, token];
    next();
end
if token == 40              % '(': parenthesised expression
    next();
    parse_expr();
    expect(41);
elseif token == 128         % Num
    em(sprintf('\tmovl\t$%d, %%eax', double(token_val)));
    next();
elseif token == 150         % Id: local variable
    name = idname;
    next();
    if ~isfield(lvars, name)
        fail(sprintf('undefined variable %s', name));
    end
    off = lvars.(name);
    em(sprintf('\tleaq\t-%d(%%rbp), %%rax', off));
    em('\tmovl\t(%rax), %eax');
else
    fail('expected a number, variable, or parenthesised expression');
end
for k = numel(ops):-1:1
    if ops(k) == 45         % '-'
        em('\tnegl\t%eax');
    elseif ops(k) == 126    % '~'
        em('\tnotl\t%eax');
    elseif ops(k) == 33     % '!': logical not — eax = (eax == 0)
        em('\tcmpl\t$0, %eax');
        em('\tsete\t%al');
        em('\tmovzbl\t%al, %eax');
    end
    % unary '+' is a no-op
end
end
