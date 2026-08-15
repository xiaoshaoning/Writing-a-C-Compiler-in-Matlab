function cc_int(varargin)
% cc_int — x86-64 assembly compiler (Norasandler "Writing a C Compiler").
%   Part 1: `return <int>;`
%   Part 2: unary operators — `return -42;`, `return ~42;`, `return !42;`,
%           unary plus, arbitrarily nested (`return -~!5;`).
%
% Emits COFF assembly for MSYS2 binutils on Windows (see README for the
% gcc invocation). Pipeline: tokenizer (next) → recursive-descent parser
% (parse_program/parse_unary) → codegen.
%
%   cc_int('in.c', 'out.s')
%   gcc out.s -o out
%   .\out.exe  (cmd)  /  ./out  (bash) — exit code is the returned value

global src si token token_val out fname

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
% next — tokenizer. Num=128, Return=130, Int=131, Main=132; single-char
% operators/braces keep their ASCII code; 0 = EOF. Skips whitespace.
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
parse_unary();
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

function parse_unary()
% parse_unary — unary := ('-' | '~' | '!' | '+')* Num. Emits `movl $N,
% %eax` then applies the operators in reverse (innermost first).
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
