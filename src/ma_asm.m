function img = ma_asm(txt)
% ma_asm - assemble the x86-64 text that cc_int emits.
%
%   img = ma_asm(txt)     txt: the .s text, as a char row or a cellstr of lines
%
% Returns an image:
%   .text   uint8 row   the .text bytes, in order
%   .data   uint8 row   the .data bytes, as written (layout is the caller's problem)
%   .bss    struct arr  .name .size .align, from .comm
%   .syms   struct arr  .name .section .offset .global
%
% Errors are thrown, not collected: `line N: <what>` names the first bad line. A variant
% that collects every error is a different function, and nobody has asked for it - which
% is the rule this project has followed all day: no knob until someone does not use the
% default.
%
% THE SCOPE IS THE MEASURED ONE. cc_int emits 51 mnemonics, 15 directives and ~25
% registers; the table in isa_table() has one row per mnemonic and nothing else. A
% mnemonic it lacks is an error with its line, never a guess.
%
% M0 state: the text is parsed into lines, sections and symbols, directives are handled,
% and every *instruction* fails - either "no encoder yet" (known mnemonic, table row
% present) or "unknown mnemonic" (not in the table). That is deliberate: the harness in
% tests/probe_assembler.m is being built first, and this failure mode is how the missing
% encoder list is generated, one line number at a time.
%
% MILESTONES (see docs/PLAN_assembler.md): M1 lines/labels/directives, M2 operands,
% M3 encoders by frequency, M4 two-pass layout and relocations, M5 the 338-program gate.

if iscell(txt)
    lines = txt(:).';
else
    % Split by hand. This file already had to give up sscanf's fourth output and
    % regexp(...,'end') because the clone implements neither, and regexp(...,'split')
    % turned out to be a third - it returned the whole text as ONE line, so ma_asm
    % assembled nothing and reported success: the exact failure mode this project
    % refuses to ship.
    lines = {};
    start = 1;
    for k = 1:numel(txt)
        if txt(k) == char(10)
            lines{end+1} = txt(start:k-1);
            start = k + 1;
        end
    end
    if start <= numel(txt)
        lines{end+1} = txt(start:end);
    end
end

img.text = uint8([]);
img.data = uint8([]);
% [] rather than struct('name',{},...): on the clone that form is a ONE-ELEMENT struct
% with empty fields, not an empty array, so every list started with a phantom entry - and
% a symbol table with a nameless member in it fails later, somewhere else. Measured:
% numel() is 1 on the clone and 0 on the engine for the struct('f',{}) form, and correct
% on both for [].
img.bss = {};
img.syms = {};     % a CELL of structs: see the note above about empty
                   % struct arrays differing per runtime

section = 'text';
tab = isa_table();

for ln = 1:numel(lines)
    line = strip_comment(lines{ln});
    if isempty(line)
        continue;
    end
    % Decide what this line is by scanning the name at its start, ONCE:
    %   <name>:            a label - and note that every local label (.Lret1, .LFB1,
    %                      .Lstr0) starts with '.', exactly like a directive does
    %   .<name>            a directive
    %   <mnemonic> ...     an instruction
    % Testing line(1) == '.' first read every dotted label as a directive, which the
    % corpus-wide run found on all 25 programs at line 6 (.LFB1).
    k = 1;
    while k <= numel(line) && is_name_char(line(k))
        k = k + 1;
    end
    is_label = (k > 1) && (k <= numel(line)) && (line(k) == ':');

    if ~is_label && line(1) == '.'
        % A directive. Plain character scanning, not sscanf's fourth output (the clone
        % does not implement it) and not regexp(...,'end') (it does not either, measured
        % in this very file). Scanning is longer and runs everywhere.
        k = 2;
        while k <= numel(line) && is_name_char(line(k))
            k = k + 1;
        end
        d = line(1:k-1);
        rest = strtrim(line(k:end));
        switch d
            case {'.text', '.data'}
                section = d(2:end);
            case {'.file', '.def', '.scl', '.type', '.endef', ...
                  '.cfi_startproc', '.cfi_endproc', '.cfi_def_cfa', ...
                  '.cfi_def_cfa_register', '.cfi_def_cfa_offset', '.cfi_offset'}
                % metadata: accepted and ignored. .def/.scl/.type and the .cfi_* family
                % describe debugging and unwinding, neither of which an image has.
            case '.globl'
                img = mark_global(img, rest);
            case '.comm'
                img = add_comm(img, rest, ln);
            case {'.byte', '.short', '.long', '.quad'}
                img = add_bytes(img, section, d, rest, ln);
            case '.string'
                img = add_string(img, section, rest, ln);
            otherwise
                fail(ln, sprintf('unknown directive %s', d));
        end
        continue;
    end

    % a label definition: `<name>:` at the start of the line (scan done above)
    if is_label
        j = sym_index(img, line(1:k-1));
        if j == 0
            img.syms{end+1} = struct('name', line(1:k-1), 'section', section, ...
                                      'offset', numel(section_bytes(img, section)), ...
                                      'global', 0);
        else
            img.syms{j}.section = section;
            img.syms{j}.offset = numel(section_bytes(img, section));
        end
        continue;
    end

    % anything else is an instruction, and M0 has no encoders
    k = 1;
    while k <= numel(line) && line(k) >= 'a' && line(k) <= 'z'
        k = k + 1;
    end
    if k == 1
        fail(ln, sprintf('cannot read this line: %s', line));
    end
    mn = line(1:k-1);
    if ~table_has(tab, mn)
        fail(ln, sprintf('unknown mnemonic %s', mn));
    end
    % M2: decode the operands even though no encoder consumes them yet. That is the point -
    % a decoder nothing calls is untested, and this one is now run over every instruction
    % in every compiled program, so a form it cannot read fails HERE with a line number
    % instead of surfacing as bad bytes in M3.
    ops = split_operands(line(k:end), ln);
    for q = 1:numel(ops)
        decode_operand(ops{q}, ln);
    end
    fail(ln, sprintf('no encoder for %s yet (M3)', mn));
end
end

% ---------------------------------------------------------------------------------

function out = strip_comment(line)
% GAS comments start at '#'. cc_int emits none, but a hand-written .s in a test may.
k = find(line == '#', 1);
if isempty(k)
    out = strtrim(line);
else
    out = strtrim(line(1:k-1));
end
end

function b = is_name_char(c)
% the characters a label, symbol or directive name may contain here
b = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || ...
    c == '_' || c == '.' || c == '$';
end

function vals = parse_int_list(rest, ln)
% parse_int_list - the comma-separated integers of a data directive.
%
% A thin loop over read_int, so this file really does have ONE integer reader - the sign,
% the hex and the refusal all live there. Its predecessor scanned values itself and used
% sscanf('%d,'), which stops at the first value it cannot read: `1, 0x10` came back as `1`
% and the rest vanished into the image without a word.
vals = [];
start = 1;
for k = 1:numel(rest)
    if rest(k) == ','
        vals(end+1) = read_int(strtrim(rest(start:k-1)), ln);
        start = k + 1;
    end
end
vals(end+1) = read_int(strtrim(rest(start:end)), ln);
end

function fail(ln, msg)
error(sprintf('ma_asm: line %d: %s', ln, msg));
end

function b = section_bytes(img, section)
if strcmp(section, 'data')
    b = img.data;
else
    b = img.text;
end
end

function img = set_section_bytes(img, section, bytes)
if strcmp(section, 'data')
    img.data = [img.data bytes];
else
    img.text = [img.text bytes];
end
end

function img = mark_global(img, name)
% .globl marks a symbol global. The symbol may be defined later, so names are recorded
% here and matched when the definition appears - defining one is M1's job.
j = sym_index(img, name);
if j == 0
    img.syms{end+1} = struct('name', name, 'section', '', 'offset', -1, 'global', 1);
else
    img.syms{j}.global = 1;
end
end

function k = sym_index(img, name)
% sym_index - the index of `name` in img.syms, or 0. `.globl f` and a later `f:` describe
% ONE symbol, so both go through here; appending blindly gave every global function two
% entries, one of them with no offset at all.
k = 0;
for j = 1:numel(img.syms)
    if strcmp(img.syms{j}.name, name)
        k = j;
        return;
    end
end
end

function img = add_comm(img, rest, ln)
[parts, count] = sscanf(rest, '%[A-Za-z0-9_.$],%d,%d', 3);
if count < 2
    fail(ln, '.comm needs a name and a size');
end
align = 8;
if count >= 3
    align = parts(3);
end
img.bss{end+1} = struct('name', parts(1), 'size', parts(2), 'align', align);
end

function img = add_bytes(img, section, d, rest, ln)
width = struct('.byte', 1, '.short', 2, '.long', 4, '.quad', 8);
w = width.(d);
vals = parse_int_list(rest, ln);
if isempty(vals)
    fail(ln, sprintf('%s with no values', d));
end
bytes = zeros(1, numel(vals) * w);
for k = 1:numel(vals)
    v = vals(k);
    for b = 0:w-1
        bytes((k-1)*w + b + 1) = mod(floor(v / 2^(8*b)), 256);
    end
end
img = set_section_bytes(img, section, uint8(bytes));
end

function img = add_string(img, section, rest, ln)
% .string "text" - GAS escapes, not C escapes. cc_int has already escaped for GAS, so
% this only has to undo the ones that change the byte: \\, \", \n, \t, \ooo.
s = strtrim(rest);
if isempty(s) || s(1) ~= '"'
    fail(ln, '.string needs a quoted literal');
end
s = s(2:end);
if ~isempty(s) && s(end) == '"'
    s = s(1:end-1);
end
out = [];
k = 1;
while k <= numel(s)
    c = s(k);
    if c ~= '\'
        out(end+1) = double(c);
        k = k + 1;
        continue;
    end
    k = k + 1;
    if k > numel(s)
        fail(ln, '.string ends in a backslash');
    end
    e = s(k);
    if e == 'n'
        out(end+1) = 10; k = k + 1;
    elseif e == 't'
        out(end+1) = 9; k = k + 1;
    elseif e == char(92)
        % '\\' is TWO characters in MATLAB, so `e == '\\'` compared a char to a 1x2
        % array and never matched - and 31 corpus strings contain an escaped backslash.
        out(end+1) = 92; k = k + 1;
    elseif e == '"'
        out(end+1) = double('"'); k = k + 1;
    elseif e == 'b'
        out(end+1) = 8;  k = k + 1;     % GAS single-character escapes. cc_int emits
    elseif e == 'f'                     % none of these (it escapes for GAS with \ and
        out(end+1) = 12; k = k + 1;     % \"), but the reference assembler accepts them,
    elseif e == 'r'                     % and refusing what as accepts makes the two
        out(end+1) = 13; k = k + 1;     % disagree for a reason that is ours, not C's.
    elseif e == 'v'
        out(end+1) = 11; k = k + 1;
    elseif e >= '0' && e <= '7'
        v = 0;
        digits = 0;
        while k <= numel(s) && s(k) >= '0' && s(k) <= '7' && digits < 3
            v = v * 8 + (double(s(k)) - 48);
            k = k + 1;
            digits = digits + 1;
        end
        out(end+1) = mod(v, 256);
    else
        fail(ln, sprintf('.string has an escape this assembler does not know: \\%s', e));
    end
end
out(end+1) = 0;      % the terminator
img = set_section_bytes(img, section, uint8(out));
end

function ops = split_operands(rest, ln)
% split_operands - the operand strings of an instruction, in order.
% Commas separate operands and nothing else in this text: the only nested punctuation is
% `(...)` around a register, which never contains a comma.
ops = {};
rest = strtrim(rest);
if isempty(rest)
    ops = {};
    return;
end
start = 1;
for k = 1:numel(rest)
    if rest(k) == ','
        ops{end+1} = strtrim(rest(start:k-1));
        start = k + 1;
    end
end
ops{end+1} = strtrim(rest(start:end));
for k = 1:numel(ops)
    if isempty(ops{k})
        fail(ln, 'an operand is empty');
    end
end
end

function o = decode_operand(txt, ln)
% decode_operand - one operand string as a structure.
%
% The six forms cc_int emits, measured over 25 corpus programs:
%   %rax            register
%   $12  $-1  $0x10 immediate (decimal, negative, hex)
%   -1004(%rbp)     displacement + base register
%   (%rax)          base register
%   .Lret1  main    a symbol, for the branch and call encoders
%   a(%rip)         symbol + rip, the data reference
%
% Fields: .kind ('reg'|'imm'|'mem'|'sym'), .reg / .base (0-15, -1 for none), .width,
% .disp, .value (immediates), .symbol, .rip.
%
% Width belongs to the REGISTER (%al is 8, %eax 32, %rax 64); .needs_rex marks the
% registers whose number is 8 or more, which the encoder must reflect in REX.B/R/X.
o.kind = '';
o.reg = -1;
o.base = -1;
o.width = 0;
o.disp = 0;
o.value = 0;
o.symbol = '';
o.rip = 0;
o.needs_rex = 0;

if isempty(txt)
    fail(ln, 'empty operand');
end

if txt(1) == '$'
    o.kind = 'imm';
    o.value = read_int(txt(2:end), ln);
    return;
end

if txt(1) == '%'
    r = reg_lookup(txt);
    if r.num < 0
        fail(ln, sprintf('unknown register %s', txt));
    end
    o.kind = 'reg';
    o.reg = r.num;
    o.width = r.width;
    o.needs_rex = (r.num >= 8) || r.wide;
    return;
end

% memory: `disp(reg)`, `(reg)`, `sym(%rip)`
open = find(txt == '(', 1);
if ~isempty(open)
    close = find(txt == ')', 1, 'last');
    if isempty(close) || close < open
        fail(ln, sprintf('unbalanced parentheses in %s', txt));
    end
    inside = txt(open+1:close-1);
    head = txt(1:open-1);
    if ~isempty(txt(close+1:end))    % trailing text after ')' is no form cc_int emits
        fail(ln, sprintf('cannot decode operand %s', txt));
    end
    o.kind = 'mem';
    if ~isempty(inside) && inside(1) == '%'
        r = reg_lookup(inside);
        if r.num < 0
            fail(ln, sprintf('unknown register in %s', txt));
        end
        o.base = r.num;
        o.needs_rex = (r.num >= 8);
        if strcmp(inside, '%rip')
            o.rip = 1;
        end
    else
        fail(ln, sprintf('memory operand without a register: %s', txt));
    end
    if ~isempty(head)
        if o.rip
            o.symbol = head;        % sym(%rip): the symbol IS the operand
        else
            o.disp = read_int(head, ln);
        end
    end
    return;
end

% a bare symbol: a branch or call target, or a data label
o.kind = 'sym';
o.symbol = txt;
end

function v = read_int(txt, ln)
% read_int - a decimal or 0x immediate, possibly negative. Same scanner the data
% directives use, so there is one integer reader in this file.
v = 0;
k = 1;
neg = 0;
if ~isempty(txt) && txt(1) == '-'
    neg = 1; k = 2;
elseif ~isempty(txt) && txt(1) == '+'
    k = 2;
end
if k + 1 <= numel(txt) && txt(k) == '0' && (txt(k+1) == 'x' || txt(k+1) == 'X')
    k = k + 2;
    while k <= numel(txt)
        c = lower(txt(k));
        if c >= '0' && c <= '9'
            v = v * 16 + (double(c) - 48);
        elseif c >= 'a' && c <= 'f'
            v = v * 16 + (double(c) - 87);
        else
            break;
        end
        k = k + 1;
    end
elseif k <= numel(txt) && txt(k) >= '0' && txt(k) <= '9'
    while k <= numel(txt) && txt(k) >= '0' && txt(k) <= '9'
        v = v * 10 + (double(txt(k)) - 48);
        k = k + 1;
    end
else
    fail(ln, sprintf('expected a number, got %s', txt));
end
if neg
    v = -v;
end
end

function r = reg_lookup(name)
% reg_lookup - the measured register set: number, width, and whether the 64-bit form
% needs REX.W. One table, because every encoder asks this question.
r.num = -1;
r.width = 0;
r.wide = 0;
tab = reg_table();
for k = 1:numel(tab)
    if strcmp(tab(k).name, name)
        r = tab(k);
        return;
    end
end
end

function tab = reg_table()
% the registers cc_int actually uses (measured), with x86-64 encoding numbers
add = @(nm, num, w, wide) struct('name', nm, 'num', num, 'width', w, 'wide', wide);
tab = [ ...
    add('%rax', 0, 64, 1); add('%rcx', 1, 64, 1); add('%rdx', 2, 64, 1);
    add('%rbx', 3, 64, 1); add('%rsp', 4, 64, 1); add('%rbp', 5, 64, 1);
    add('%rsi', 6, 64, 1); add('%rdi', 7, 64, 1);
    add('%r8', 8, 64, 1);  add('%r9', 9, 64, 1);
    add('%r10', 10, 64, 1); add('%r11', 11, 64, 1);
    add('%eax', 0, 32, 0); add('%ebx', 3, 32, 0); add('%edx', 2, 32, 0);
    add('%al', 0, 8, 0);   add('%cl', 1, 8, 0);   add('%dl', 2, 8, 0);
    add('%xmm0', 0, 128, 0); add('%xmm1', 1, 128, 0);
    add('%rip', -2, 64, 0) ...   % -2: not a register, a marker the mem encoder
                                 % recognises, because -1 already means 'no base'
];
end

function b = table_has(tab, mn)
b = 0;
for k = 1:numel(tab)
    if strcmp(tab(k).mnemonic, mn)
        b = 1;
        return;
    end
end
end

function tab = isa_table()
% isa_table - one row per mnemonic cc_int emits, with the encoder family it needs.
%
% The list is MEASURED: 25 diverse corpus programs were compiled and every mnemonic
% counted (docs/PLAN_assembler.md). `kind` names the encoder that M3 will fill in; it is
% data, not code, so adding an instruction is adding a row.
%
% kind values, once implemented: 'rm' (reg/mem forms), 'imm', 'jmp', 'call', 'setcc',
% 'sse', 'none' (nothing yet).
add = @(m, k) struct('mnemonic', m, 'kind', k);
tab = [ ...
    add('movq', 'rm'); add('movl', 'rm'); add('movb', 'rm'); add('movabsq', 'imm');
    add('movslq', 'rm'); add('movsbq', 'rm'); add('movzbl', 'rm'); add('movsd', 'sse');
    add('leaq', 'rm'); add('pushq', 'rm'); add('popq', 'rm');
    add('addq', 'rm'); add('subq', 'rm'); add('imulq', 'imm'); add('idivq', 'rm');
    add('divq', 'rm'); add('negq', 'rm'); add('incq', 'rm'); add('cqto', 'none');
    add('andq', 'rm'); add('orq', 'rm'); add('xorq', 'rm'); add('xorl', 'rm');
    add('notq', 'rm'); add('shlq', 'imm'); add('shrq', 'imm'); add('sarq', 'imm');
    add('cmpq', 'rm'); add('testb', 'rm');
    add('jmp', 'jmp'); add('je', 'jmp'); add('jne', 'jmp'); add('jg', 'jmp');
    add('jge', 'jmp'); add('jl', 'jmp'); add('jle', 'jmp'); add('ja', 'jmp');
    add('jae', 'jmp'); add('jbe', 'jmp');
    add('call', 'call'); add('ret', 'none');
    add('sete', 'setcc'); add('setne', 'setcc'); add('setg', 'setcc');
    add('mulsd', 'sse'); add('divsd', 'sse'); add('addsd', 'sse'); add('subsd', 'sse');
    add('ucomisd', 'sse'); add('cvtsi2sdq', 'sse'); add('cvttsd2siq', 'sse') ...
];
end
