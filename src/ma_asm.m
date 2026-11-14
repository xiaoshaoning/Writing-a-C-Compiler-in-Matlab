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
% The parse phase builds ITEMS, not bytes: a label is a position, and a branch is a
% choice of size that cannot be made until every label has one. Sections are separate
% item lists because a branch never crosses one.
items.text = {};
items.data = {};

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
                items = push_item(items, section, item_bytes(add_bytes(d, rest, ln)));
            case '.string'
                items = push_item(items, section, item_bytes(add_string(rest, ln)));
            otherwise
                fail(ln, sprintf('unknown directive %s', d));
        end
        continue;
    end

    % a label definition: `<name>:` at the start of the line (scan done above)
    if is_label
        items = push_item(items, section, item_label(line(1:k-1)));
        if ~isempty(strtrim(line(k+1:end)))
            % GAS allows `label: instruction` on one line. cc_int never emits it, and
            % silently DROPPING the instruction (which is what this did) is the worst of
            % the three possible behaviours: the label lands at the right offset and the
            % code vanishes. Measured on a hand-written test file whose every line was
            % written that way - 23 instructions, 0 bytes, no error.
            fail(ln, 'a label and an instruction on one line is not supported');
        end
        continue;
    end

    % an instruction
    k = 1;
    while k <= numel(line) && line(k) >= 'a' && line(k) <= 'z'
        k = k + 1;
    end
    if k == 1
        fail(ln, sprintf('cannot read this line: %s', line));
    end
    mn = line(1:k-1);
    if isempty(tab_kind(tab, mn))
        fail(ln, sprintf('unknown mnemonic %s', mn));
    end
    % The decoder runs on every instruction of every program, so a form it cannot read
    % fails HERE with a line number instead of becoming bad bytes later.
    ops = split_operands(line(k:end), ln);
    decoded = cell(1, numel(ops));
    for q = 1:numel(ops)
        decoded{q} = decode_operand(ops{q}, ln);
    end
    if has_symbol_rip(decoded)
        % leaq .Lret1(%rip), %rax and friends: same-section labels resolve, so this
        % cannot be encoded until the labels have offsets.
        bytes = encode_insn(mn, decoded, ln, tab);
        items = push_item(items, section, ...
                          item_rip(mn, decoded, first_symbol(decoded), bytes, ln));
    elseif is_reloc(mn, tab)
        % A branch's size depends on how far away its target ends up, and that is a
        % property of the whole section - so it is an item, resolved in layout below.
        items = push_item(items, section, item_reloc(mn, decoded{1}.symbol, ln));
    else
        items = push_item(items, section, item_bytes(encode_insn(mn, decoded, ln, tab)));
    end
end

% not `[img, img.text, ...] = ...`: an indexed assignment inside a multi-output list is
% accepted by the clone and refused by the engine ("indexed assignment base must be a
% variable"). A temporary is portable and reads no worse.
[img, tb, items.text] = lay_out(img, 'text', items.text);
img.text = tb;
[img, db, items.data] = lay_out(img, 'data', items.data);
img.data = db;
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
% fail - a source error, with its line. ln <= 0 means an internal invariant broke, which is
% not something the input can fix, and "line 0:" would read as the input's fault.
if ln > 0
    error(sprintf('ma_asm: line %d: %s', ln, msg));
else
    error(sprintf('ma_asm: internal: %s', msg));
end
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
    e2 = img.syms{j};
    e2.global = 1;
    img.syms{j} = e2;
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

function bytes = add_bytes(d, rest, ln)
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
bytes = uint8(bytes);
end

function bytes = add_string(rest, ln)
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
bytes = uint8(out);
end

function items = push_item(items, section, it)
% push_item - append to a section's item list. Not `items.(section){end+1} = it`: the
% engine refuses a chained assignment target, and the clone accepts it, so the chained
% form passes here and fails there.
lst = items.(section);
lst{end+1} = it;
items.(section) = lst;
end

function it = item_bytes(b)
it = struct('kind', 'bytes', 'b', uint8(b), 'name', '', 'mn', '', ...
            'target', '', 'ln', 0, 'short', 0, 'ops', {{}});
end

function it = item_label(name)
it = struct('kind', 'label', 'b', uint8([]), 'name', name, 'mn', '', ...
            'target', '', 'ln', 0, 'short', 0, 'ops', {{}});
end

function it = item_rip(mn, ops, target, bytes, ln)
% a rip-relative reference to a symbol: its bytes are final only once the layout knows
% where the symbol is, so the operands are kept and the instruction is re-encoded.
it = struct('kind', 'rip', 'b', uint8(bytes), 'name', '', 'mn', mn, ...
            'target', target, 'ln', ln, 'short', 0, 'ops', {{}});
% assigned AFTER construction: struct('f', {cellvalue}) makes a struct ARRAY with one
% element per cell entry, not a struct with a cell field. Same trap as struct('f',{}),
% which is why the symbol tables here are cells of structs.
it.ops = ops;
end

function it = item_reloc(mn, target, ln)
% a branch or a call: its bytes are decided in layout, because they depend on where the
% target lands - which is the whole reason this phase exists.
it = struct('kind', 'reloc', 'b', uint8([]), 'name', '', 'mn', mn, ...
            'target', target, 'ln', ln, 'short', 0, 'ops', {{}});
end

function f = has_symbol_rip(ops)
% has_symbol_rip - true when any operand is a rip-relative reference to a named symbol
f = 0;
for q = 1:numel(ops)
    if strcmp(ops{q}.kind, 'mem') && ops{q}.rip && ~isempty(ops{q}.symbol)
        f = 1;
    end
end
end

function s2 = first_symbol(ops)
s2 = '';
for q = 1:numel(ops)
    if strcmp(ops{q}.kind, 'mem') && ops{q}.rip && ~isempty(ops{q}.symbol)
        s2 = ops{q}.symbol;
        return;
    end
end
end

function b = is_reloc(mn, tab)
k = tab_kind(tab, mn);
b = strcmp(k, 'jmp') || strcmp(k, 'call');
end

function n = reloc_size(it)
% the size a branch or call occupies at its current form
if strcmp(it.mn, 'call')
    n = 5;                                  % e8 rel32, always
elseif it.short
    n = 2;                                  % eb rel8 / 7x rel8
elseif strcmp(it.mn, 'jmp')
    n = 5;                                  % e9 rel32
else
    n = 6;                                  % 0f 8x rel32
end
end

function n = item_size(it)
if strcmp(it.kind, 'reloc')
    n = reloc_size(it);
elseif strcmp(it.kind, 'label')
    n = 0;
else
    n = numel(it.b);
end
end

function [img, bytes, items] = lay_out(img, section, items)
% lay_out - assign every label an offset, narrow every branch that fits, then emit.
%
% Iteration, not two passes: `as` chooses the SHORT form for a forward branch when it fits
% (measured - a jmp to a label 23 bytes ahead comes out `eb 15`), so the form of one
% branch affects the offsets of everything after it, which affects later branches. Sizes
% only ever shrink, so this converges; the loop bound is a guard against a bug, not a
% budget.
for pass = 1:16
    changed = 0;
    off = 0;
    for j = 1:numel(items)
        it = items{j};
        if strcmp(it.kind, 'label')
            items{j} = it;                   % offsets are recomputed below
            off = off;
        elseif strcmp(it.kind, 'reloc') && ~it.short && ~strcmp(it.mn, 'call')
            % would the short form reach the target from here?
            tgt = label_offset_in(items, it.target);
            if tgt >= 0
                d = tgt - (off + 2);
                if d >= -128 && d <= 127
                    it2 = items{j};
                    it2.short = 1;
                    items{j} = it2;      % not items{j}.short = 1: the engine refuses a
                    changed = 1;         % chained assignment target outright
                end
            end
        end
        off = off + item_size(items{j});
    end
    if ~changed
        break;
    end
end

% emit: bytes now, offsets now, and the symbol table's answer for this section
bytes = uint8([]);
off = 0;
for j = 1:numel(items)
    it = items{j};
    if strcmp(it.kind, 'label')
        sym = sym_index(img, it.name);
        if sym == 0
            img.syms{end+1} = struct('name', it.name, 'section', section, ...
                                     'offset', off, 'global', 0);
        else
            e2 = img.syms{sym};
            e2.section = section;
            e2.offset = off;
            img.syms{sym} = e2;
        end
    elseif strcmp(it.kind, 'rip')
        tgt = label_offset_in(items, it.target);
        if tgt < 0
            bytes = [bytes it.b];             % another section (or external): zeros, as as does
        else
            ops2 = it.ops;
            for q = 1:numel(ops2)
                if strcmp(ops2{q}.kind, 'mem') && ops2{q}.rip && ~isempty(ops2{q}.symbol)
                    ops2{q}.ripdisp = tgt - (off + numel(it.b));
                end
            end
            bytes = [bytes encode_insn(it.mn, ops2, it.ln, isa_table())];
        end
    elseif strcmp(it.kind, 'reloc')
        tgt = label_offset_in(items, it.target);
        if tgt < 0 && ~strcmp(it.mn, 'call')
            % a branch to a label that is not in this section is a real error
            fail(it.ln, sprintf('unresolved symbol %s', it.target));
        end
        if tgt < 0
            % An EXTERNAL call - the shims reach the real printf and malloc. The reference
            % emits a zero displacement and a relocation, so zeros are what byte equality
            % wants; resolving them is the linker's job, not this assembler's.
            if strcmp(it.mn, 'call')
                bytes = [bytes 232 0 0 0 0];
            else
                fail(it.ln, sprintf('unresolved branch target %s', it.target));
            end
        elseif strcmp(it.mn, 'call')
            bytes = [bytes 232 rel_bytes(tgt - (off + 5), 4)];
        elseif it.short
            if strcmp(it.mn, 'jmp')
                bytes = [bytes 235 rel_bytes(tgt - (off + 2), 1)];
            else
                bytes = [bytes jcc_short(it.mn) rel_bytes(tgt - (off + 2), 1)];
            end
        else
            if strcmp(it.mn, 'jmp')
                bytes = [bytes 233 rel_bytes(tgt - (off + 5), 4)];
            else
                bytes = [bytes 15 jcc_near(it.mn) rel_bytes(tgt - (off + 6), 4)];
            end
        end
    else
        bytes = [bytes it.b];
    end
    off = off + item_size(it);
end
end

function off = label_offset_in(items, name)
% the offset of a label in this section, or -1. Walks the items the same way lay_out does,
% so there is one notion of where a label is.
off = -1;
at = 0;
for j = 1:numel(items)
    if strcmp(items{j}.kind, 'label') && strcmp(items{j}.name, name)
        off = at;
        return;
    end
    at = at + item_size(items{j});
end
end

function b = rel_bytes(v, n)
% a signed displacement, little-endian, n bytes
if n == 1
    if v < -128 || v > 127
        fail(0, sprintf('internal: rel8 out of range (%d)', v));
    end
end
b = le_bytes(v, n);
end

function op = jcc_short(mn)
% the 7x short-jump opcode for each condition
switch mn
    case 'je',  op = 116;
    case 'jne', op = 117;
    case 'jl',  op = 124;
    case 'jge', op = 125;
    case 'jle', op = 126;
    case 'jg',  op = 127;
    case 'jb',  op = 114;
    case 'jae', op = 115;
    case 'jbe', op = 118;
    case 'ja',  op = 119;
    otherwise,  error('jcc_short: not a conditional branch');
end
end

function op = jcc_near(mn)
% the 8x opcode after 0F for each condition
switch mn
    case 'je',  op = 132;
    case 'jne', op = 133;
    case 'jl',  op = 140;
    case 'jge', op = 141;
    case 'jle', op = 142;
    case 'jg',  op = 143;
    case 'jb',  op = 130;
    case 'jae', op = 131;
    case 'jbe', op = 134;
    case 'ja',  op = 135;
    otherwise,  error('jcc_near: not a conditional branch');
end
end

function bytes = encode_insn(mn, ops, ln, tab)
% encode_insn - one instruction's bytes, dispatched by SHAPE rather than by name.
%
% The ALU family is six mnemonics with one shape and six opcode bytes, the shift family is
% three with one shape and three extents, and so on. Encoding by name would be an if-chain
% twenty long; encoding by shape means a new mnemonic is usually one row in a family table.
%
% Every opcode below is what `as` chooses, measured rather than derived. Three short forms
% would have been missed from the encoding tables:
%   movl $5, %eax     b8 ...        imm->reg, 32-bit - not c7 /0
%   cmpq $500, %rax   48 3d ...     the accumulator form, when imm8 does not fit
%   shlq $1, %rax     48 d1 e0      shift-by-one, not c1 /4 01
kind = tab_kind(tab, mn);
switch kind
    case 'alu'
        bytes = enc_alu(mn, ops, ln);
    case 'shift'
        bytes = enc_shift(mn, ops, ln);
    case 'unary'
        bytes = enc_unary(mn, ops, ln);
    case 'lea'
        bytes = enc_lea(mn, ops, ln);
    case 'movx'
        bytes = enc_movx(mn, ops, ln);
    case 'mov'
        bytes = enc_mov(mn, ops, ln);
    case 'stack'
        bytes = enc_stack(mn, ops, ln);
    case 'setcc'
        bytes = enc_setcc(mn, ops, ln);
    case 'misc'
        bytes = enc_misc(mn, ops, ln);
    otherwise
        fail(ln, sprintf('no encoder for %s yet (M3)', mn));
end
end

function k = tab_kind(tab, mn)
k = '';
for j = 1:numel(tab)
    if strcmp(tab(j).mnemonic, mn)
        k = tab(j).kind;
        return;
    end
end
end

function b = rexp(w, reg_hi, base_hi)
% rexp - the REX prefix, or empty when none is needed.
% R is the register in the ModRM reg field; B is the register in the r/m field (a register
% or a memory operand's base). X is for a SIB index, which none of the measured forms uses.
v = 64;
if w,       v = v + 8; end
if reg_hi,  v = v + 4; end
if base_hi, v = v + 1; end
if v == 64
    b = [];
else
    b = v;
end
end

function b = modrmb(mod, reg, rm)
b = mod * 64 + mod_low(reg) * 8 + mod_low(rm);
end

function v = mod_low(r)
% the low three bits of a register number. A negative number is a sentinel (-1 "no
% register", -2 rip) and must never reach an encoding: mod_low(-2) is 6, which would
% quietly encode %rsi.
if r < 0
    fail(0, sprintf('internal: register sentinel %d reached the ModRM field', r));
end
v = r - 8 * floor(r / 8);
end

function [m, extra] = mem_form(e)
% mem_form - the ModRM byte for a memory operand in the r/m position (its reg field is
% zero for the caller to fill) and the bytes after it. Three rules, all in the corpus:
%   %rsp/%r12 needs a SIB byte even with no index
%   %rbp/%r13 with displacement 0 must use disp8=0 (mod 00 r/m 101 means rip-relative)
%   a displacement that fits in a signed byte uses one byte, otherwise four
base = e.base;
lo = mod_low(base);
sib = [];
if lo == 4
    sib = 36;                                   % scale 0, no index, base 100
    if e.disp == 0
        m = lo;
        extra = sib;
        return;
    end
end
if e.disp == 0 && lo ~= 5
    m = lo;
    extra = sib;
elseif e.disp >= -128 && e.disp <= 127
    m = 64 + lo;
    extra = [sib le_bytes(e.disp, 1)];
else
    m = 128 + lo;
    extra = [sib le_bytes(e.disp, 4)];
end
end

function f = imm_fits_32(v)
% imm_fits_32 - true when v survives sign-extension from 32 bits, which is what the
% c7 /0 id form does to its immediate.
lo = mod(v, 4294967296);
if lo >= 2147483648
    lo = lo - 4294967296;
end
f = (lo == v);
end

function b = le_bytes(v, n)
u = mod(v, 2^(8*n));
b = zeros(1, n);
for k = 1:n
    b(k) = mod(floor(u / 2^(8*(k-1))), 256);
end
end

function [prefix, mrm, tail] = rm_operand(op, reg_field, w)
% rm_operand - an operand as the r/m field: a register, or memory with its base, SIB and
% displacement. w asks for the 64-bit operand size.
if strcmp(op.kind, 'reg')
    prefix = rexp(w, floor(reg_field / 8), floor(op.reg / 8));
    mrm = modrmb(3, reg_field, op.reg);
    tail = [];
elseif strcmp(op.kind, 'mem')
    if op.rip
        prefix = rexp(w, floor(reg_field / 8), 0);
        mrm = modrmb(0, reg_field, 5);          % mod 00, r/m 101: rip-relative
        % Same-section labels resolve here (the emit pass fills ripdisp in). A label in
        % another section stays 0, which is exactly what the reference emits - measured:
        % `leaq .Lx(%rip)` with .Lx in .data assembles to 48 8d 05 00 00 00 00, and the
        % linker resolves it later.
        tail = le_bytes(op.ripdisp, 4);
    else
        prefix = rexp(w, floor(reg_field / 8), floor(op.base / 8));
        [mrm, extra] = mem_form(op);
        mrm = mrm + mod_low(reg_field) * 8;
        tail = extra;
    end
else
    fail(0, 'rm_operand called with a non-register, non-memory operand');
end
end

function spec = alu_spec(mn)
% r_to_rm, rm_to_r, extent (the /digit of the immediate forms), acc (the accumulator short
% form). Measured from as, one row per mnemonic - adding `testb` to this family would be a
% row, not a function.
switch mn
    case 'addq', spec = [1 3 0 5];
    case 'orq',  spec = [9 11 1 13];
    case 'andq', spec = [33 35 4 37];
    case 'subq', spec = [41 43 5 45];
    case {'xorq', 'xorl'}, spec = [49 51 6 53];   % same opcodes; w comes from the suffix
    case 'cmpq', spec = [57 59 7 61];
    otherwise,   spec = [];
end
end

function bytes = enc_alu(mn, ops, ln)
% enc_alu - add/sub/cmp/and/or/xor: one shape, six opcode sets, and a width taken from the
% mnemonic's suffix (xorl is the 32-bit form and carries no REX).
spec = alu_spec(mn);
if isempty(spec) || numel(ops) ~= 2
    fail(ln, sprintf('no encoder for %s yet (M3)', mn));
end
w = 0;
if ~isempty(mn) && mn(end) == 'q'
    w = 1;
end
src = ops{1};
dst = ops{2};
if strcmp(src.kind, 'imm')
    if src.value >= -128 && src.value <= 127
        [pre, mrm, tail] = rm_operand(dst, spec(3), w);
        bytes = [pre 131 mrm tail le_bytes(src.value, 1)];            % 83 /digit ib
    elseif strcmp(dst.kind, 'reg') && dst.reg == 0
        bytes = [rexp(w, 0, 0) spec(4) le_bytes(src.value, 4)];       % accumulator short form
    else
        [pre, mrm, tail] = rm_operand(dst, spec(3), w);
        bytes = [pre 129 mrm tail le_bytes(src.value, 4)];            % 81 /digit id
    end
    return;
end
if strcmp(src.kind, 'mem') && strcmp(dst.kind, 'reg')
    [pre, mrm, tail] = rm_operand(src, dst.reg, w);
    bytes = [pre spec(2) mrm tail];                                   % r/m -> reg
else
    [pre, mrm, tail] = rm_operand(dst, src.reg, w);
    bytes = [pre spec(1) mrm tail];                                   % reg -> r/m
end
end

function bytes = enc_shift(mn, ops, ln)
% enc_shift - shl/shr/sar by an immediate or by %cl. Shift by one has its own form (D1),
% which as uses and the general rule would miss.
switch mn
    case 'shlq', slot = 4;
    case 'shrq', slot = 5;
    case 'sarq', slot = 7;
    otherwise,   slot = -1;
end
if slot < 0 || numel(ops) ~= 2
    fail(ln, sprintf('no encoder for %s yet (M3)', mn));
end
dst = ops{2};
if strcmp(ops{1}.kind, 'imm')
    v = ops{1}.value;
    [pre, mrm, tail] = rm_operand(dst, slot, 1);
    if v == 1
        bytes = [pre 209 mrm tail];                                   % D1 /digit
    else
        bytes = [pre 193 mrm tail le_bytes(v, 1)];                    % C1 /digit ib
    end
elseif strcmp(ops{1}.kind, 'reg') && ops{1}.reg == 1 && ops{1}.width == 8
    % D3 takes the count from CL implicitly - the encoding has no field for it - so any
    % other 8-bit register would be silently encoded as CL.
    [pre, mrm, tail] = rm_operand(dst, slot, 1);
    bytes = [pre 211 mrm tail];                                       % D3 /digit, count in %cl
else
    fail(ln, sprintf('%s: the count must be an immediate or %%cl', mn));
end
end

function bytes = enc_unary(mn, ops, ln)
% enc_unary - not/neg are F7 /2 and /3, inc is FF /0; all take one r/m operand
switch mn
    case 'notq', opcode = 247; slot = 2;
    case 'negq', opcode = 247; slot = 3;
    case 'incq', opcode = 255; slot = 0;
    otherwise,   opcode = 0;   slot = -1;
end
if opcode == 0 || numel(ops) ~= 1
    fail(ln, sprintf('no encoder for %s yet (M3)', mn));
end
[pre, mrm, tail] = rm_operand(ops{1}, slot, 1);
bytes = [pre opcode mrm tail];
end

function bytes = enc_lea(mn, ops, ln)
% enc_lea - 8D /r: a memory address into a register. The operand must be memory; leaq on a
% register is not a form cc_int emits and is not valid C either.
if numel(ops) ~= 2 || ~strcmp(ops{1}.kind, 'mem')
    fail(ln, sprintf('%s takes a memory operand and a register', mn));
end
[pre, mrm, tail] = rm_operand(ops{1}, ops{2}.reg, 1);
bytes = [pre 141 mrm tail];
end

function bytes = enc_movx(mn, ops, ln)
% enc_movx - the sign/zero-extending loads. Two share the 0F map and one does not:
%   movslq  63 /r      single-byte opcode
%   movsbq  0F BE /r
%   movzbl  0F B6 /r
% Treating movslq as a 0F form (which this function did for one commit) writes 48 0F 63
% where as writes 48 63 - caught by the byte gate, not by reading.
switch mn
    case 'movslq', op2 = 99;  w = 1; has0f = 0;
    case 'movsbq', op2 = 190; w = 1; has0f = 1;
    case 'movzbl', op2 = 182; w = 0; has0f = 1;
    otherwise,    op2 = 0;    w = 0; has0f = 0;
end
if op2 == 0 || numel(ops) ~= 2
    fail(ln, sprintf('no encoder for %s yet (M3)', mn));
end
[pre, mrm, tail] = rm_operand(ops{1}, ops{2}.reg, w);
if has0f
    bytes = [pre 15 op2 mrm tail];
else
    bytes = [pre op2 mrm tail];
end
end

function bytes = enc_mov(mn, ops, ln)
% enc_mov - movq (w=1), movl (w=0), movb (w=0, byte registers). The immediate-to-register
% form differs by width: c7 /0 for 64-bit, b8+rd for 32-bit. That asymmetry is as's, and
% matching it is the job.
switch mn
    case 'movq', w = 1;
    case 'movl', w = 0;
    case 'movb', w = 0;
    otherwise,   w = -1;
end
if w < 0 || numel(ops) ~= 2
    fail(ln, sprintf('no encoder for %s yet (M3)', mn));
end
src = ops{1};
dst = ops{2};
if strcmp(src.kind, 'imm')
    if strcmp(dst.kind, 'reg')
        if w == 1 && imm_fits_32(src.value)
            bytes = [rexp(1, 0, floor(dst.reg / 8)) 199 modrmb(3, 0, dst.reg) ...
                     le_bytes(src.value, 4)];                    % movq: c7 /0 id
        elseif w == 1
            % c7 /0 id SIGN-EXTENDS its 32-bit immediate, so it only reproduces the value
            % when the value fits in a signed 32 bits. For anything else as emits movabs
            % (48 b8+rd io, 10 bytes). Measured: `movq $5,%rax` is 48 c7 c0 05 00 00 00
            % and `movq $0xb2d05e00,%rax` is 48 b8 00 5e d0 b2 00 00 00 00 - the long
            % form is not optional there, the short one would store a different number.
            bytes = [rexp(1, 0, floor(dst.reg / 8)) 184 + mod_low(dst.reg) ...
                     le_bytes(src.value, 8)];
        elseif strcmp(mn, 'movb')
            bytes = [rexp(0, 0, floor(dst.reg / 8)) 176 + mod_low(dst.reg) ...
                     le_bytes(src.value, 1)];                    % movb: b0+rb ib
        else
            bytes = [rexp(0, 0, floor(dst.reg / 8)) 184 + mod_low(dst.reg) ...
                     le_bytes(src.value, 4)];                    % movl: b8+rd id
        end
    else
        % No immediate-to-memory form reaches past 32 bits, and as TRUNCATES here rather
        % than choosing a longer form - a `movq $4294967289, -8(%rbp)` from the corpus
        % assembles to c7 45 f8 f9 ff ff ff. Refusing it would have been stricter than the
        % reference and broken a program the reference assembles.
        [pre, mrm, tail] = rm_operand(dst, 0, w);
        bytes = [pre 199 mrm tail le_bytes(src.value, 4)];
    end
    return;
end
% movb has its own opcodes: 88 /r store, 8A /r load. Using the 32-bit pair would move a
% different number of bytes and still look plausible.
if strcmp(mn, 'movb')
    op_load = 138;
    op_store = 136;
else
    op_load = 139;
    op_store = 137;
end
if strcmp(src.kind, 'mem') && strcmp(dst.kind, 'reg')
    [pre, mrm, tail] = rm_operand(src, dst.reg, w);
    bytes = [pre op_load mrm tail];                                   % 8B/8A /r
else
    [pre, mrm, tail] = rm_operand(dst, src.reg, w);
    bytes = [pre op_store mrm tail];                                  % 89/88 /r
end
end

function bytes = enc_stack(mn, ops, ln)
% pushq/popq: 50+rd / 58+rd, no ModRM, no operand-size prefix
if numel(ops) ~= 1 || ~strcmp(ops{1}.kind, 'reg')
    fail(ln, sprintf('%s takes one register', mn));
end
r = ops{1}.reg;
if strcmp(mn, 'pushq')
    op = 80 + mod_low(r);
else
    op = 88 + mod_low(r);
end
if r >= 8
    bytes = [65 op];
else
    bytes = op;
end
end

function bytes = enc_setcc(mn, ops, ln)
% setcc - 0f 9x /0; a byte store, so the operand is an 8-bit register
switch mn
    case 'sete',  op2 = 148;
    case 'setne', op2 = 149;
    case 'setg',  op2 = 159;
    case 'setl',  op2 = 156;
    case 'setge', op2 = 157;
    case 'setle', op2 = 158;
    case 'seta',  op2 = 151;
    case 'setb',  op2 = 146;
    otherwise,    op2 = 0;
end
if op2 == 0 || numel(ops) ~= 1 || ~strcmp(ops{1}.kind, 'reg')
    fail(ln, sprintf('no encoder for %s yet (M3)', mn));
end
[pre, mrm, tail] = rm_operand(ops{1}, 0, 0);
bytes = [pre 15 op2 mrm tail];
end

function bytes = enc_misc(mn, ops, ln)
% the one-shape leftovers: ret, cqto, idivq/divq, testb, movabsq
switch mn
    case 'ret'
        bytes = 195;                                                  % C3
    case 'cqto'
        bytes = [72 153];                                             % 48 99
    case {'idivq', 'divq'}
        if numel(ops) ~= 1
            fail(ln, sprintf('%s takes one operand', mn));
        end
        if strcmp(mn, 'idivq')
            slot = 7;
        else
            slot = 6;
        end
        [pre, mrm, tail] = rm_operand(ops{1}, slot, 1);
        bytes = [pre 247 mrm tail];                                   % F7 /7, F7 /6
    case 'testb'
        if numel(ops) ~= 2
            fail(ln, 'testb takes two operands');
        end
        [pre, mrm, tail] = rm_operand(ops{2}, ops{1}.reg, 0);
        bytes = [pre 132 mrm tail];                                   % 84 /r
    case 'movabsq'
        if numel(ops) ~= 2 || ~strcmp(ops{1}.kind, 'imm') || ~strcmp(ops{2}.kind, 'reg')
            fail(ln, 'movabsq takes an immediate and a register');
        end
        bytes = [rexp(1, 0, floor(ops{2}.reg / 8)) 184 + mod_low(ops{2}.reg) ...
                 le_bytes(ops{1}.value, 8)];                          % 48 b8+rd imm64
    otherwise
        fail(ln, sprintf('no encoder for %s yet (M3)', mn));
end
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
% .disp, .value (immediates), .symbol, .rip, and .ripdisp - the displacement a
% rip-relative reference ends up with, which only the layout can compute.
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
o.ripdisp = 0;      % filled in by the emit pass for a same-section label
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
        % width, not a non-negative number: %rip is a sentinel with number -2, and -1
        % already means "not a register". Testing num < 0 rejected every `g(%rip)`.
        if r.width == 0
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
    % r12-r15 are not in the measured set - cc_int stops at r11 - but the SIB and REX.B
    % rules differ for r12/r13, so an assembler that cannot encode them is wrong even
    % if this compiler never asks. r13 is also the second rbp-like base for disp rules.
    add('%r12', 12, 64, 1); add('%r13', 13, 64, 1);
    add('%r14', 14, 64, 1); add('%r15', 15, 64, 1);
    add('%eax', 0, 32, 0); add('%ebx', 3, 32, 0); add('%edx', 2, 32, 0);
    add('%al', 0, 8, 0);   add('%cl', 1, 8, 0);   add('%dl', 2, 8, 0);
    add('%xmm0', 0, 128, 0); add('%xmm1', 1, 128, 0);
    add('%rip', -2, 64, 0) ...   % -2: not a register, a marker the mem encoder
                                 % recognises, because -1 already means 'no base'
];
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
    add('movq', 'mov'); add('movl', 'mov'); add('movb', 'mov');
    add('movslq', 'movx'); add('movsbq', 'movx'); add('movzbl', 'movx');
    add('leaq', 'lea'); add('pushq', 'stack'); add('popq', 'stack');
    add('addq', 'alu'); add('subq', 'alu'); add('cmpq', 'alu');
    add('andq', 'alu'); add('orq', 'alu'); add('xorq', 'alu'); add('xorl', 'alu');
    add('notq', 'unary'); add('negq', 'unary'); add('incq', 'unary');
    add('shlq', 'shift'); add('shrq', 'shift'); add('sarq', 'shift');
    add('imulq', 'imm');
    add('movabsq', 'misc'); add('idivq', 'misc'); add('divq', 'misc');
    add('cqto', 'misc'); add('testb', 'misc'); add('movsd', 'sse');
    add('jmp', 'jmp'); add('je', 'jmp'); add('jne', 'jmp'); add('jg', 'jmp');
    add('jge', 'jmp'); add('jl', 'jmp'); add('jle', 'jmp'); add('ja', 'jmp');
    add('jae', 'jmp'); add('jbe', 'jmp');
    add('call', 'call'); add('ret', 'misc');
    add('sete', 'setcc'); add('setne', 'setcc'); add('setg', 'setcc');
    add('setl', 'setcc'); add('setge', 'setcc'); add('setle', 'setcc');
    add('seta', 'setcc'); add('setb', 'setcc');
    add('mulsd', 'sse'); add('divsd', 'sse'); add('addsd', 'sse'); add('subsd', 'sse');
    add('ucomisd', 'sse'); add('cvtsi2sdq', 'sse'); add('cvttsd2siq', 'sse') ...
];
end
