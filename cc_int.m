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
%
% Emits COFF assembly for MSYS2 binutils on Windows (see README for the
% gcc invocation). Pipeline: tokenizer (next) → recursive-descent parser
% (parse_program/parse_expr/…) → codegen.
%
%   cc_int('in.c', 'out.s')
%   gcc out.s -o out
%   .\out.exe  (cmd)  /  ./out  (bash) — exit code is the returned value

global src si token token_val out fname lbl

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
out = '';

next();
parse_program();

fid_output = fopen(destination_file, 'w+');
if fid_output < 0
    error(sprintf('could not open(%s)', destination_file));
end
fprintf(fid_output, '%s', out);
fclose(fid_output);
end

% ---------------------------------------------------------------------------
% helpers
% ---------------------------------------------------------------------------

function fail(msg)
% fail — abort compilation with a message.
error(msg);
end

function em(line)
% em — append one assembly line to the output buffer. MATLAB strings do
% not process C escapes, so a literal backslash-t becomes a tab (part 1
% relied on fprintf-format-string escape processing; this path does not).
global out
out = [out, strrep(line, '\t', char(9)), char(10)];
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
% next — tokenizer. Num=128, Return=130, Int=131, Main=132, Shl=140,
% Shr=141, Lan=142, Lor=143, Lt=144, Gt=145, Le=146, Ge=147, Eq=148,
% Ne=149; single-char operators/braces keep their ASCII code; 0 = EOF.
% Skips whitespace.
global src si token token_val
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
    elseif strcmp(id, 'main')
        token = 132;            % Main
    else
        fail(sprintf('unknown identifier %s', id));
    end
    return;
elseif c == '='
    si = si + 1;
    if si <= numel(src) && src(si) == '='
        si = si + 1;
        token = 148;            % Eq
    else
        fail('expected == (no assignment in part 5)');
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
% parse_program — int main() { return <unary>; } — emit the .s template
% around the parsed body.
global token out fname
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

expect(131);    % int
expect(132);    % main
expect(40);     % (
expect(41);     % )
expect(123);    % {
expect(130);    % return
parse_expr();
expect(59);     % ;
expect(125);    % }
if token ~= 0
    fail('trailing tokens after the main body');
end

em('\tpopq\t%rbp');
em('\t.cfi_def_cfa 7, 8');
em('\tret');
em('\t.cfi_endproc');
em('.LFE0:');
end

function parse_expr()
% expression := logical_or
parse_logical_or();
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
% shift := unary (('<<' | '>>') unary)* — left-associative; the shift
% count goes in %cl; '>>' is an arithmetic shift (signed int).
global token
parse_unary();
while token == 140 || token == 141   % Shl Shr
    op = token;
    next();
    em('\tpushq\t%rax');        % save the left operand
    parse_unary();
    em('\tmovl\t%eax, %ecx');   % shift count in %cl
    em('\tpopq\t%rax');
    if op == 140
        em('\tshll\t%cl, %eax');
    else
        em('\tsarl\t%cl, %eax');
    end
end
end

function parse_unary()
% unary := ('-' | '~' | '!' | '+')* Num. Emits `movl $N, %eax` then
% applies the operators in reverse (innermost first).
global token token_val
ops = [];
while token == 45 || token == 126 || token == 33 || token == 43   % - ~ ! +
    ops = [ops, token];
    next();
end
if token ~= 128
    fail('expected a number after the unary operators');
end
em(sprintf('\tmovl\t$%d, %%eax', double(token_val)));
next();
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
