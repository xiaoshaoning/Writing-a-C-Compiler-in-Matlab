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
img.bss = struct('name', {}, 'size', {}, 'align', {});
img.syms = struct('name', {}, 'section', {}, 'offset', {}, 'global', {});

section = 'text';
tab = isa_table();

for ln = 1:numel(lines)
    line = strip_comment(lines{ln});
    if isempty(line)
        continue;
    end
    if line(1) == '.'
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

    % a label definition: `<name>:` at the start of the line
    k = 1;
    while k <= numel(line) && is_name_char(line(k))
        k = k + 1;
    end
    if k > 1 && k <= numel(line) && line(k) == ':'
        img.syms(end+1) = struct('name', line(1:k-1), 'section', section, ...
                                 'offset', numel(section_bytes(img, section)), 'global', 0);
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

function fail(ln, msg)
error('ma_asm: line %d: %s', ln, msg);
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
for k = 1:numel(img.syms)
    if strcmp(img.syms(k).name, name)
        img.syms(k).global = 1;
        return;
    end
end
img.syms(end+1) = struct('name', name, 'section', '', 'offset', -1, 'global', 1);
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
img.bss(end+1) = struct('name', parts(1), 'size', parts(2), 'align', align);
end

function img = add_bytes(img, section, d, rest, ln)
width = struct('.byte', 1, '.short', 2, '.long', 4, '.quad', 8);
w = width.(d);
vals = sscanf(rest, '%d,');
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
    elseif e == '\\'
        out(end+1) = double('\'); k = k + 1;
    elseif e == '"'
        out(end+1) = double('"'); k = k + 1;
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
tab = struct('mnemonic', {}, 'kind', {});
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
