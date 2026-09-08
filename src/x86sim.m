function varargout = x86sim(sfile, inputs)
% x86sim — a mini x86-64 simulator for the assembly emitted by cc_int.m.
%
% Runs the generated .s directly — no assembler, linker, or gcc. Parses
% the COFF-ish directives, lays out .comm/.data/.string symbols in a byte
% memory, and interprets the instruction stream with a register file,
% flags, and a downward-growing stack.  Emulates the CRT entry (call
% main; the exit code = rax) and the runtime-library symbols the shims
% forward to.
%
%   exit_code = x86sim('out.s')                   % normal run
%   outs      = x86sim('mex.s', {x1, x2, ...})    % mex mode: builds the
%                                                  % harness prhs (the
%                                                  % corpus's __mex_*
%                                                  % globals), runs main,
%                                                  % and returns the plhs
%                                                  % as MATLAB arrays
%
% All text is processed as double code vectors: the clone mangles certain
% string literals (e.g. 'sum', 'count', 'set') when they cross local-
% function boundaries, so names are compared as code vectors.

global MEMSZ DATA_BASE CODE_BASE STACK_TOP MHEAP
global mem symnames symvals clnames clvals code regs xmms zf sf cf of pf fids simdone sim_mex_locked sim_mat
MEMSZ  = 4 * 1024 * 1024;
DATA_BASE = 4096;
CODE_BASE = DATA_BASE + MEMSZ;
STACK_TOP = DATA_BASE + MEMSZ - 16;
MHEAP = DATA_BASE + MEMSZ / 2;
% mem is allocated after pass 1: the stack starts at DATA_BASE+MEMSZ-16
% and call pushes return addresses above CODE_BASE, so the array must
% cover [0, CODE_BASE + <code length> + slack).
symnames = {};  symvals = [];    % data symbol code-vectors -> byte address
clnames = {};   clvals = [];     % code label code-vectors -> instruction index
code = {};
regs = zeros(1, 16, 'int64');
xmms = zeros(1, 16);            % SSE registers: hold the double VALUE
                                % (not the bit pattern: the clone's
                                % numeric model cannot hold arbitrary
                                % 64-bit patterns exactly)
zf = 0; sf = 0; cf = 0; of = 0; pf = 0;
fids = struct();
simdone = 0;
sim_mex_locked = 0;   % mexLock/mexUnlock state (within and across runs)

% ---- read the source as a double code vector ----
fid = fopen(sfile, 'r');
if fid < 0
    error(sprintf('x86sim: could not open(%s)', sfile));
end
src = char(fread(fid, inf, 'uint8')');
fclose(fid);
srcC = double(src);
lines = sim_strsplit(srcC);

% ---- pass 1: data layout + code lines ----
% The clone's cell auto-grow is O(n) per append (calloc + copy), so
% building the instruction cell via code{end+1} is O(n^2) — preallocate
% to numel(lines) and trim the unused tail instead.
cursor = DATA_BASE;
NL = numel(lines);
symnames = cell(1, NL);  symvals = zeros(1, NL);   sym_n = 0;
clnames = cell(1, NL);   clvals = zeros(1, NL);    cl_n = 0;
code = cell(1, NL);                                 code_n = 0;
pending = cell(1, NL);                              pend_n = 0;
mode = 'text';
plab = [];                     % a pending label awaiting data/code resolution
for li = 1:NL
    L = lines{li};
    if L(end) == 58 && isempty(sim_find(L, 9))      % ':' label, no tab
        lab = cv_slice(L, 1, numel(L)-1);
        if strcmp(mode, 'data')
            sym_n = sym_n + 1;
            symnames{sym_n} = lab;
            symvals(sym_n) = cursor;
        elseif ~(numel(lab) >= 3 && lab(1) == 46 && lab(2) == 76 && lab(3) == 70)
            % not a .LF marker: resolve any pending label (a label followed
            % by a label in the text section is a code label), then hold
            % the new one pending for the next item
                        if ~isempty(plab)
                cl_n = cl_n + 1;
                clnames{cl_n} = plab;
                clvals(cl_n) = code_n + 1;
            end
            plab = lab;
        end
        continue;
    end
    if L(1) == 46              % '.': a directive
        [d, rest] = sim_split_first(L);
        if cv_eq(d, cv_of('.text'))
            mode = 'text';
        elseif cv_eq(d, cv_of('.data'))
            mode = 'data';
        elseif cv_eq(d, cv_of('.comm'))
            if ~isempty(plab)
                sym_n = sym_n + 1;
                symnames{sym_n} = plab;
                symvals(sym_n) = cursor;
                plab = [];
            end
            parts = sim_split_commas(rest);
            nm = sim_trim(parts{1});
            sz = str2double(cv_char(parts{2}));
            aln = 8;
            if numel(parts) >= 3
                aln = str2double(cv_char(parts{3}));
            end
            cursor = cursor + mod(-cursor, aln);
            sym_n = sym_n + 1;
            symnames{sym_n} = nm;
            symvals(sym_n) = cursor;
            cursor = cursor + sz;
        elseif cv_eq(d, cv_of('.quad')) || cv_eq(d, cv_of('.byte'))
            if ~isempty(plab)
                sym_n = sym_n + 1;
                symnames{sym_n} = plab;
                symvals(sym_n) = cursor;
                plab = [];
            end
            nb = 8;
            if cv_eq(d, cv_of('.byte'))
                nb = 1;
            end
            parts = sim_split_commas(rest);
            for k = 1:numel(parts)
                p = sim_trim(parts{k});
                pend_n = pend_n + 1;
                if ~isempty(p) && p(1) == 46
                    pending{pend_n} = {cursor, nb, p};   % a label reference
                else
                    pending{pend_n} = {cursor, nb, sim_num64(p)};
                end
                cursor = cursor + nb;
            end
        elseif cv_eq(d, cv_of('.string'))
            if ~isempty(plab)
                sym_n = sym_n + 1;
                symnames{sym_n} = plab;
                symvals(sym_n) = cursor;
                plab = [];
            end
            txt = sim_unescape(rest);
            pend_n = pend_n + 1;
            pending{pend_n} = {cursor, 1, [double('S'), txt]};
            cursor = cursor + numel(txt) + 1;
        end
        continue;
    end
    if strcmp(mode, 'text')
        if ~isempty(plab)
            cl_n = cl_n + 1;
            clnames{cl_n} = plab;
            clvals(cl_n) = code_n + 1;
            plab = [];
        end
        code_n = code_n + 1;
        code{code_n} = sim_parse_insn(L);
    end
end
% The clone's cell SLICING (c(1:n)) is broken (returns empty), so trim
% by rebuilding a fresh cell with a loop.
if code_n > 0
    code2 = cell(1, code_n);
    for k = 1:code_n
        code2{k} = code{k};
    end
    code = code2;
else
    code = {};
end
if cl_n > 0
    clnames2 = cell(1, cl_n);
    for k = 1:cl_n
        clnames2{k} = clnames{k};
    end
    clnames = clnames2;
    clvals = clvals(1:cl_n);
else
    clnames = {};
    clvals = [];
end
if sym_n > 0
    symnames2 = cell(1, sym_n);
    for k = 1:sym_n
        symnames2{k} = symnames{k};
    end
    symnames = symnames2;
    symvals = symvals(1:sym_n);
else
    symnames = {};
    symvals = [];
end
if pend_n > 0
    pending2 = cell(1, pend_n);
    for k = 1:pend_n
        pending2{k} = pending{k};
    end
    pending = pending2;
else
    pending = {};
end
% ---- mem: [0, CODE_BASE) plus room for call return-address pushes ----
mem = zeros(1, CODE_BASE + numel(code) + 64, 'uint8');

% ---- pass 2: emit the data bytes (resolve label references) ----
for k = 1:numel(pending)
    e = pending{k};
    v = e{3};
    if numel(v) >= 1 && v(1) == double('S')
        sim_store_bytes(e{1}, v(2:end));
    elseif numel(v) >= 1 && v(1) == 46     % '.Lstr...' label reference
        ad = sym_get(v);
        sim_storeN(e{1}, ad, 8);
    else
        % a numeric literal: store the full directive width (e{2})
        % bytes. sim_store_bytes writes numel(v) bytes (one per element),
        % so a scalar .quad wrote only its low byte (100000 -> 160, a
        % 0x4024... double pattern -> 0), corrupting every multi-byte
        % global (.long/.quad ints AND .quad double-pattern globals).
        sim_storeN(e{1}, v, e{2});
    end
end

steps = 0;
n = numel(code);
% ---- run: CRT entry ----
if cl_get(cv_of('main')) < 0
    error('x86sim: no main');
end
regs(5) = int64(STACK_TOP);
sim_rsp_push(0);              % the sentinel return address
pc = cl_get(cv_of('main'));
n = numel(code);
steps = 0;
maxsteps = 50000000;
mex_flag = 0;
% mex mode is driven by the harness (mex_run passes an inputs cell even
% when empty): a no-input oracle MEX call still reads back plhs and sees
% __mex_nrhs = 0 (the fresh .comm).  The raw harness mains run with a
% single argument and stay in exit-code mode.
if nargin >= 2 && iscell(inputs)
    mex_flag = 1;
    pbase = sym_get(cv_of('__mex_prhs'));
    qbase = sym_get(cv_of('__mex_plhs'));
    nrsec = sym_get(cv_of('__mex_nrhs'));
    if pbase < 0 || qbase < 0
        error('x86sim: mex mode needs __mex_prhs/__mex_plhs globals');
    end
    nk = numel(inputs);
        for k = 1:nk
        v = inputs{k};
        % char/double/int matrices live in the sim heap as MATLAB-COLUMN-
        % MAJOR memory (matching the clone's real_data and the C code's
        % i + j*m indexing); cells/structs/sparse/complex get dedicated
        % layouts via mat2sim.
        h = mat2sim(v);
        sim_storeN(pbase + 8 * (k - 1), h, 8);
    end
    if nrsec >= 0
        sim_storeN(nrsec, nk, 8);
    end
end
while pc >= 1 && pc <= n && simdone == 0
    insn = code{pc};
    pc = sim_exec(insn, pc);
    steps = steps + 1;
    if steps > maxsteps
        error('x86sim: step limit exceeded (possible infinite loop)');
    end
end
exit_code = double(regs(1));
if mex_flag
    qbase = sym_get(cv_of('__mex_plhs'));
    outs = {};
    for k = 1:4
        h = double(sim_load64(qbase + 8 * (k - 1)));
        if h == 0
            continue;
        end
        outs{end+1} = sim_mx2mat(h);
    end
    varargout = {outs, exit_code};
else
    varargout = {exit_code};
end
end

% --------------------------------------------------------------------------
function pc = sim_exec(insn, pc)
global regs code clnames clvals simdone CODE_BASE zf sf cf of pf
m = insn{1};

a = insn{2};
b = insn{3};
next = pc + 1;
if m == 0                % movq
    if b{1} == 2 && b{2} >= 17 && a{1} == 2 && a{2} < 17
        % gpr -> xmm: the gpr holds the IEEE PATTERN of a double; xmm
        % registers hold VALUES (the clone cannot hold arbitrary 64-bit
        % patterns in its numeric model, so doubles never live as
        % patterns inside xmm)
        sim_regwrite(b{2}, 64, sim_bits2d(sim_opval(a)));
    elseif b{1} == 2 && b{2} >= 17 && a{1} == 3
        % movq mem -> xmm (pattern view; the compiler uses movsd instead)
        sim_regwrite(b{2}, 64, sim_bytes2d(sim_effaddr(a)));
    else
        v = sim_opval(a);
        sim_opstore(b, v, 64);
    end
elseif m == 1            % movl / xorl (32-bit, zero-extends)
    v = sim_dwordval(a);
    sim_opstore(b, v, 32);
elseif m == 2            % movzbl
    v = sim_byteval(a);
    sim_opstore(b, v, 32);
elseif m == 3            % movsbl
    v = sim_byteval(a);
    if v >= 128
        v = v - 256;
    end
    sim_opstore(b, v, 32);
elseif m == 4            % movb
    v = mod(sim_opval(a), 256);
    sim_opstore(b, v, 8);
elseif m == 65           % movzwl: 2-byte zero-extend load
    v = sim_wordval(a);
    sim_opstore(b, v, 32);
elseif m == 66           % movw: 2-byte store
    v = mod(sim_opval(a), 65536);
    sim_opstore(b, v, 16);
elseif m == 5            % leaq
    sim_opstore(b, sim_effaddr(a), 64);
elseif m == 6            % pushq
    sim_rsp_push(sim_opval(a));
elseif m == 7            % popq
    sim_opstore(a, sim_rsp_pop(), 64);
elseif m == 8            % addq
    sim_opstore(b, sim_opval(b) + sim_opval(a), 64);
elseif m == 9            % subq
    sim_opstore(b, sim_opval(b) - sim_opval(a), 64);
elseif m == 10           % imulq
    sim_opstore(b, sim_opval(b) * sim_opval(a), 64);
elseif m == 11           % andq
    sim_opstore(b, bitand(sim_opval(b), sim_opval(a), 'int64'), 64);
elseif m == 12           % orq
    sim_opstore(b, bitor(sim_opval(b), sim_opval(a), 'int64'), 64);
elseif m == 13           % xorq
    sim_opstore(b, bitxor(sim_opval(b), sim_opval(a), 'int64'), 64);
elseif m == 14           % negq
    sim_opstore(a, -sim_opval(a), 64);
elseif m == 15           % notq
    sim_opstore(a, bitxor(sim_opval(a), int64(-1)), 64);
elseif m == 16           % incq
    sim_opstore(a, sim_opval(a) + 1, 64);
elseif m == 17           % shlq
    c = mod(sim_opval(a), 64);
    sim_opstore(b, bitshift(sim_opval(b), c, 'int64'), 64);
elseif m == 39           % sarq (arithmetic)
    c = mod(sim_opval(a), 64);
    sim_opstore(b, bitshift(sim_opval(b), -c, 'int64'), 64);
elseif m == 44           % shrq (logical, unsigned)
    c = double(mod(sim_opval(a), 64));
    u = mod(double(sim_opval(b)), 18446744073709551616);
    sim_opstore(b, int64(floor(u / 2^c)), 64);
elseif m == 18           % cmpq
    sim_setflags_cmp(sim_opval(b), sim_opval(a));
elseif m == 19           % testb
    r = bitand(mod(sim_opval(b), 256), mod(sim_opval(a), 256), 'int64');
    sim_setflags_test(r);
elseif m == 20           % cqto
    if regs(1) < 0
        regs(3) = int64(-1);
    else
        regs(3) = int64(0);
    end
elseif m == 21           % idivq (signed)
    dv = sim_opval(a);
    if dv == 0
        error('x86sim: division by zero');
    end
    q = fix(double(regs(1)) / double(dv));
    r = double(regs(1)) - q * double(dv);
    regs(1) = int64(q);
    regs(3) = int64(r);
elseif m == 45           % divq (unsigned): rdx:rax / src
    dv = mod(double(sim_opval(a)), 18446744073709551616);
    if dv == 0
        error('x86sim: division by zero');
    end
    ua = mod(double(regs(1)), 18446744073709551616);
    q = floor(ua / dv);
    r = ua - q * dv;
    regs(1) = int64(mod(q, 18446744073709551616));
    regs(3) = int64(mod(r, 18446744073709551616));
elseif (m >= 22 && m <= 27) || (m >= 40 && m <= 43)   % setcc family
    k = m - 22;
    if m >= 40
        k = m - 32;              % setb(40)..setae(43) -> k 8..11
    end
    vvv = sim_jcc(k);
    sim_opstore(a, vvv, 8);
elseif m >= 28 && m <= 36   % jmp je jne jl jle jg jge jz jnz
    if m == 28 || sim_jcc(m - 29)
        next = sim_target(a);
    end
elseif m >= 46 && m <= 49   % ja jb jae jbe (unsigned branches)
    if m == 46, k = 9;
    elseif m == 47, k = 8;
    elseif m == 48, k = 11;
    else k = 10; end
    if sim_jcc(k)
        next = sim_target(a);
    end
elseif m == 37           % call
    tgt = sim_target(a);
    if tgt >= 0
        sim_rsp_push(CODE_BASE + pc + 1);
        next = tgt;
    else
        sim_libcall(a{2});
        next = pc + 1;
    end
elseif m == 38           % ret
    v = sim_rsp_pop();
    if v == 0
        next = -1;
    else
        next = double(v) - CODE_BASE;
    end
elseif m >= 50 && m <= 55   % movsd addsd subsd mulsd divsd xorpd
    if m == 50              % movsd: VALUE moves (mem<->xmm, xmm<->xmm)
        if b{1} == 3
        end
        va = sim_opval(a);
        if a{1} == 3 && b{1} == 2       % mem -> xmm
            va = sim_bytes2d(sim_effaddr(a));
            sim_regwrite(b{2}, 64, va);
        elseif a{1} == 2 && b{1} == 3   % xmm -> mem
            sim_d2bytes(sim_opval(a), sim_effaddr(b));
        else
            sim_opstore(b, va, 64);     % xmm<->xmm / gpr fallback
        end
    elseif m == 55          % xorpd: bitwise xor of the two patterns
        v = bitxor(mod(double(sim_opval(a)), 18446744073709551616), ...
                   mod(double(sim_opval(b)), 18446744073709551616));
        sim_opstore(b, int64(mod(v, 18446744073709551616)), 64);
    else
        % double arithmetic: xmm operands are VALUES
        xa = sim_opval(a);
        xb = sim_opval(b);
        if m == 51
            r = xb + xa;
        elseif m == 52
            r = xb - xa;
        elseif m == 53
            r = xb * xa;
        else
            r = xb / xa;
        end
        sim_opstore(b, r, 64);
    end
elseif m == 56           % cvtsi2sdq src(gpr/mem), %xmm: int64 -> double VALUE
    sim_opstore(b, double(sim_opval(a)), 64);
elseif m == 57           % cvttsd2siq %xmm, gpr: double VALUE -> int64 (truncate)
    x = sim_opval(a);
    if isnan(x)
        sim_opstore(b, int64(0), 64);   % keep tests sane on NaN input
    else
        sim_opstore(b, int64(fix(x)), 64);
    end
elseif m == 58           % ucomisd: compare (b vs a), VALUES
    global zf sf cf of pf
    xa = sim_opval(a);
    xb = sim_opval(b);
    dd = fopen('D:/tmp/mxdbg.txt','a'); fprintf(dd,' uc %.17g | %.17g', xb, xa); fclose(dd);
    if isnan(xa) || isnan(xb)
        zf = 1; cf = 1; of = 0; sf = 0; pf = 1;   % unordered
    elseif xb == xa
        zf = 1; cf = 0; of = 0; sf = 0; pf = 0;
    elseif xb < xa
        zf = 0; cf = 1; of = 0; sf = 0; pf = 0;
    else
        zf = 0; cf = 0; of = 0; sf = 0; pf = 0;
    end
elseif m == 59           % setnp %al: al = !PF
    global pf zf cf
    sim_opstore(a, 1 - pf, 8);
elseif m == 60           % andb %cl, %al: 8-bit and
    v = bitand(mod(sim_opval(a), 256), mod(sim_opval(b), 256), 'int64');
    sim_opstore(b, v, 8);
else
    error('x86sim: unsupported instruction');
end
pc = next;
end

function t = sim_jcc(k)
% k: 0 sete/je/jz, 1 setne/jne/jnz, 2 setl/jl, 3 setle/jle, 4 setg/jg,
% 5 setge/jge, 6 jz, 7 jnz, 8 setb, 9 seta, 10 setbe, 11 setae
global zf sf of cf
if k == 0 || k == 6
    t = (zf == 1);
elseif k == 1 || k == 7
    t = (zf == 0);
elseif k == 2
    t = (sf ~= of);
elseif k == 3
    t = (zf == 1) || (sf ~= of);
elseif k == 4
    t = (zf == 0) && (sf == of);
elseif k == 5
    t = (sf == of);                          % setge/jge
elseif k == 8 || k == 10
    t = (cf == 1) || (k == 10 && zf == 1);   % setb / setbe
elseif k == 11
    t = (cf == 0);                           % setae
else
    t = (cf == 0) && (zf == 0);              % seta
end
end

function tgt = sim_target(a)
global clnames clvals CODE_BASE
if a{1} == 6                     % {6, namecodes}: a code label or library
    tgt = -1;
    if a{3} >= 0                 % already resolved to an index
        tgt = a{3};
    else
        tgt = cl_get(a{2});
    end
elseif a{1} == 7                 % {7, regidx}: call *%rax
    global regs
    tgt = double(regs(a{2})) - CODE_BASE + 1;
else
    error('x86sim: bad jump target');
end
end

% --------------------------------------------------------------------------
function v = sim_opval(a)
global mem
k = a{1};
if k == 1
    v = a{2};
elseif k == 2
    v = sim_regread(a{2}, a{3});
elseif k == 3
    v = sim_load64(sim_effaddr(a));
else
    error('x86sim: bad operand value');
end
end

function v = sim_byteval(a)
% sim_byteval — read ONE byte from an operand. Loading the full 8 bytes
% and masking loses the low byte for values beyond 2^53 (doubles cannot
% represent them), so char loads from a string with nonzero following
% bytes (e.g. "abcd" followed by another string) returned garbage.
global mem
if a{1} == 3
    v = double(mem(sim_effaddr(a) + 1));
elseif a{1} == 2
    v = double(mod(sim_regread(a{2}, a{3}), 256));
else
    v = mod(a{2}, 256);
end
end

function v = sim_dwordval(a)
% sim_dwordval — read FOUR bytes (little-endian) from an operand for the
% 32-bit loads (movl).  Reading exactly 4 bytes keeps packed integer
% elements from overrunning their block's end (sim_load64+mask would
% read 8 bytes and blow up on a 12-byte int32 array at the heap edge).
global mem
if a{1} == 3
    ad = sim_effaddr(a);
    v = double(mem(ad + 1)) + 256 * double(mem(ad + 2)) + ...
        65536 * double(mem(ad + 3)) + 16777216 * double(mem(ad + 4));
elseif a{1} == 2
    v = double(mod(sim_regread(a{2}, a{3}), 4294967296));
else
    v = mod(a{2}, 4294967296);
end
end

function v = sim_wordval(a)
% sim_wordval — read TWO bytes (little-endian) from an operand for the
% 2-byte loads (movzwl).  Byte-by-byte reads keep the low 16 bits exact.
global mem
if a{1} == 3
    ad = sim_effaddr(a);
    v = double(mem(ad + 1)) + 256 * double(mem(ad + 2));
elseif a{1} == 2
    v = double(mod(sim_regread(a{2}, a{3}), 65536));
else
    v = mod(a{2}, 65536);
end
end

function sim_opstore(a, v, bits)
global mem
if a{1} == 2
    sim_regwrite(a{2}, bits, v);
elseif a{1} == 3
    sim_storeN(sim_effaddr(a), v, bits / 8);
else
    error('x86sim: bad operand store');
end
end

function ad = sim_effaddr(a)
global symnames symvals clnames clvals regs CODE_BASE
if numel(a) >= 7 && ~isempty(a{7})
    ad = sym_get(a{7});
    if ad < 0
        ci = cl_get(a{7});
        if ci >= 0
            ad = CODE_BASE + ci - 1;
        else
            ad = 0;
        end
    end
    return;
end
ad = a{2};
if a{3} > 0
    ad = ad + double(regs(a{3}));
end
if a{5} > 0
    ad = ad + double(regs(a{5}));
end
ad = ad + a{6};
end

function sim_setflags_alu(r)
global zf sf cf of
r = double(r);
zf = (r == 0);
sf = (r < 0);
cf = 0; of = 0;
end

function sim_setflags_test(r)
% testb flags: ZF from zero, SF from bit 7 (the operand is a byte), CF/OF
% clear. sim_setflags_alu would never set SF (0..255 is never negative).
global zf sf cf of
zf = (r == 0);
sf = (r >= 128);
cf = 0; of = 0;
end

function sim_setflags_cmp(d, s)
global zf sf cf of
d = double(d); s = double(s);
r = d - s;
zf = (r == 0);
sf = (r < 0);
cf = (mod(d, 18446744073709551616) < mod(s, 18446744073709551616));
of = 0;
if (d < 0 && s >= 0 && r >= 0) || (d >= 0 && s < 0 && r < 0)
    of = 1;
end
end

% --------------------------------------------------------------------------
function sim_regwrite(idx, bits, v)
global regs xmms
if idx >= 17               % SSE register: store the double VALUE
    xmms(idx - 16) = double(v);
    return;
end
if bits == 64
    regs(idx) = int64(v);
elseif bits == 32
    regs(idx) = int64(mod(double(v), 4294967296));
elseif bits == 16
    cur = double(regs(idx));
    regs(idx) = int64(cur - mod(cur, 65536) + mod(double(v), 65536));
else
    % 8-bit register write (setcc/%al): the compiler zero-extends with
    % movzbl right after, so clearing the upper bits is safe; anything
    % else loses the low byte through the clone's big mod anyway
    regs(idx) = int64(mod(double(v), 256));
end
end

function v = sim_regread(idx, bits)
global regs xmms
if idx >= 17               % SSE register
    v = xmms(idx - 16);
    return;
end
r = double(regs(idx));
if bits == 8
    v = mod(r, 256);
elseif bits == 16
    v = mod(r, 65536);
elseif bits == 32
    v = mod(r, 4294967296);
else
    % 64-bit: return the RAW int64 bit pattern.  double() would round
    % values above 2^53 and destroy IEEE patterns / high addresses.
    v = regs(idx);
end
end

function sim_rsp_push(v)
global regs mem
regs(5) = regs(5) - 8;
sim_storeN(double(regs(5)), v, 8);
end

function v = sim_rsp_pop()
global regs mem
v = sim_load64(double(regs(5)));
regs(5) = regs(5) + 8;
end

function sim_mx(namecodes)
% sim_mx — the MX/mex layer operating on the simulated heap.  An mxArray
% is an 80-byte header at a heap address ("handle"):
%   +0  magic 'MXAR'   +8  class_id   +16 flags (bit0 = complex)
%   +24 rank           +32..+48 dims[3]   +56 pr   +64 pi   +72 refcount
% Data lives in separately-allocated blocks addressed by pr/pi.  The
% Win64-packed args are in regs(2)/regs(3)/regs(9)/regs(10); return
% values go in regs(1) for int/pointer and in xmms(1) for double.
% Extended headers:  struct (+80 nfields, +88 fieldnames block),
%                    sparse (+80 ir, +88 jc, +96 nzmax).
global regs xmms mem sim_mex_locked
nm = cv_char(namecodes);
if strcmp(nm, 'mxCreateDoubleMatrix')
    h = sim_mx_new(6, [double(regs(2)) double(regs(3))], double(regs(9)));
    regs(1) = int64(h);
elseif strcmp(nm, 'mxCreateDoubleScalar')
    h = sim_mx_new(6, [1 1], 0);
    pr = double(sim_load64(h + 56));
    sim_d2bytes(sim_bits2d(regs(2)), pr);
    regs(1) = int64(h);
elseif strcmp(nm, 'mxCreateNumericMatrix')
    h = sim_mx_new(double(regs(9)), ...
                   [double(regs(2)) double(regs(3))], double(regs(10)));
    regs(1) = int64(h);
elseif strcmp(nm, 'mxCreateString')
    sc = mem_strcodes(double(regs(2)));
    h = sim_mx_new(4, [1 max(1, numel(sc))], 0);
    pr = double(sim_load64(h + 56));
    for k = 1:numel(sc)
        sim_storeN(pr + (k - 1) * 8, sc(k), 8);
    end
    regs(1) = int64(h);
elseif strcmp(nm, 'mxCreateCharArray')
    h = sim_mx_new(4, [double(regs(2)) double(regs(3))], 0);
    regs(1) = int64(h);
elseif strcmp(nm, 'mxGetPr') || strcmp(nm, 'mxGetData')
    regs(1) = sim_load64(double(regs(2)) + 56);
elseif strcmp(nm, 'mxGetPi')
    regs(1) = sim_load64(double(regs(2)) + 64);
elseif strcmp(nm, 'mxGetChars')
    regs(1) = sim_load64(double(regs(2)) + 56);   % char data address
elseif strcmp(nm, 'mxGetM')
    regs(1) = sim_load64(double(regs(2)) + 32);
elseif strcmp(nm, 'mxGetN')
    regs(1) = sim_load64(double(regs(2)) + 40);
elseif strcmp(nm, 'mxGetNumberOfElements')
    regs(1) = int64(sim_mx_numel(double(regs(2))));
elseif strcmp(nm, 'mxGetScalar')
    h = double(regs(2));
    pr = double(sim_load64(h + 56));
    if pr == 0
        v = 0;
    else
        v = sim_bytes2d(pr);
    end
    xmms(1) = v;
    regs(1) = sim_d2bits(v);
elseif strcmp(nm, 'mxGetClassID')
    regs(1) = sim_load64(double(regs(2)) + 8);
elseif strcmp(nm, 'mxGetClassName')
    regs(1) = int64(sim_mx_cname(double(sim_load64(double(regs(2)) + 8))));
elseif strcmp(nm, 'mxGetDimensions')
    regs(1) = int64(double(regs(2)) + 32);
elseif strcmp(nm, 'mxGetElementSize')
    regs(1) = int64(sim_mx_elsize(double(sim_load64(double(regs(2)) + 8))));
elseif strcmp(nm, 'mxIsDouble')
    regs(1) = int64(double(sim_load64(double(regs(2)) + 8)) == 6);
elseif strcmp(nm, 'mxIsChar')
    regs(1) = int64(double(sim_load64(double(regs(2)) + 8)) == 4);
elseif strcmp(nm, 'mxIsComplex')
    regs(1) = int64(mod(double(sim_load64(double(regs(2)) + 16)), 2) == 1);
elseif strcmp(nm, 'mxIsLogical')
    regs(1) = int64(double(sim_load64(double(regs(2)) + 8)) == 3);
elseif strcmp(nm, 'mxIsInt8')
    regs(1) = int64(double(sim_load64(double(regs(2)) + 8)) == 8);
elseif strcmp(nm, 'mxIsUint8')
    regs(1) = int64(double(sim_load64(double(regs(2)) + 8)) == 9);
elseif strcmp(nm, 'mxIsInt16')
    regs(1) = int64(double(sim_load64(double(regs(2)) + 8)) == 10);
elseif strcmp(nm, 'mxIsUint16')
    regs(1) = int64(double(sim_load64(double(regs(2)) + 8)) == 11);
elseif strcmp(nm, 'mxIsInt32')
    regs(1) = int64(double(sim_load64(double(regs(2)) + 8)) == 12);
elseif strcmp(nm, 'mxIsUint32')
    regs(1) = int64(double(sim_load64(double(regs(2)) + 8)) == 13);
elseif strcmp(nm, 'mxIsInt64')
    regs(1) = int64(double(sim_load64(double(regs(2)) + 8)) == 14);
elseif strcmp(nm, 'mxIsUint64')
    regs(1) = int64(double(sim_load64(double(regs(2)) + 8)) == 15);
elseif strcmp(nm, 'mxGetInt8s') || strcmp(nm, 'mxGetUint8s') || ...
        strcmp(nm, 'mxGetInt16s') || strcmp(nm, 'mxGetUint16s') || ...
        strcmp(nm, 'mxGetInt32s') || strcmp(nm, 'mxGetUint32s') || ...
        strcmp(nm, 'mxGetInt64s') || strcmp(nm, 'mxGetUint64s')
    regs(1) = sim_load64(double(regs(2)) + 56);   % the data address
elseif strcmp(nm, 'mxIsNaN')
    v = sim_bits2d(regs(2));          % the arg is the double VALUE
    regs(1) = int64(isnan(v));
elseif strcmp(nm, 'mxIsInf')
    v = sim_bits2d(regs(2));          % the arg is the double VALUE
    regs(1) = int64(isinf(v));
    regs(2) = regs(2);
elseif strcmp(nm, 'mxIsEmpty')
    regs(1) = int64(sim_mx_numel(double(regs(2))) == 0);
elseif strcmp(nm, 'mxGetString')
    h = double(regs(2));
    dst = double(regs(3));
    buflen = double(regs(9));
    pr = double(sim_load64(h + 56));
    n = max(0, min(buflen - 1, sim_mx_numel(h)));
    k = 0;
    while k < n
        c = double(sim_load64(pr + k * 8));
        mem(dst + k + 1) = uint8(mod(c, 256));   % sim mem is 1-based
        k = k + 1;
    end
    mem(dst + n + 1) = uint8(0);
    regs(1) = int64(0);
elseif strcmp(nm, 'mxArrayToString')
    sc = sim_mx_string(double(regs(2)));
    if isempty(sc)
        regs(1) = int64(0);
    else
        a = sim_malloc(numel(sc) + 1);
        for k = 1:numel(sc)
            mem(a + k) = uint8(sc(k));          % k starts at 1: a+1..a+n
        end
        mem(a + numel(sc) + 1) = uint8(0);
        regs(1) = int64(a);
    end
elseif strcmp(nm, 'mxDuplicateArray')
    regs(1) = int64(sim_mx_dup(double(regs(2))));
elseif strcmp(nm, 'mxDestroyArray') || strcmp(nm, 'mxFree')
    regs(1) = int64(0);   % arena heap: no real destructor
elseif strcmp(nm, 'mxSetData')
    sim_storeN(double(regs(2)) + 56, regs(3), 8);   % pr IS the pointer value
    regs(1) = int64(0);
elseif strcmp(nm, 'mxAssert')
    if double(regs(2)) == 0
        fprintf('Assertion failed\n');
        regs(1) = int64(-2);
    else
        regs(1) = int64(0);
    end
elseif strcmp(nm, 'mexPrintf')
    fmt = mem_strcodes(double(regs(2)));
    n = sim_printf(fmt, regs(3), regs(9), regs(10));
    regs(1) = int64(n);
elseif strcmp(nm, 'mexEvalString')
    regs(1) = int64(0);
elseif strcmp(nm, 'mxIsCell')
    regs(1) = int64(double(sim_load64(double(regs(2)) + 8)) == 1);
elseif strcmp(nm, 'mxCreateCellMatrix')
    % the pr block is the element-handle array (numel x 8 bytes)
    h = sim_mx_new(1, [double(regs(2)) double(regs(3))], 0);
    pr = double(sim_load64(h + 56));
    for k = 1:sim_mx_numel(h)
        sim_storeN(pr + (k - 1) * 8, 0, 8);
    end
    regs(1) = int64(h);
elseif strcmp(nm, 'mxGetCell')
    h = double(regs(2));
    pr = double(sim_load64(h + 56));
    i = double(regs(3));
    regs(1) = sim_load64(pr + i * 8);
elseif strcmp(nm, 'mxSetCell')
    % the value argument IS the element handle (an int) — store it as-is
    h = double(regs(2));
    pr = double(sim_load64(h + 56));
    i = double(regs(3));
    sim_storeN(pr + i * 8, regs(9), 8);
    regs(1) = int64(0);
elseif strcmp(nm, 'mxIsStruct')
    regs(1) = int64(double(sim_load64(double(regs(2)) + 8)) == 2);
elseif strcmp(nm, 'mxCreateStructMatrix')
    % header +16 extra: +80 nfields, +88 fieldnames block; pr = the
    % field-major element-handle block (numel*nfields x 8 bytes)
    h = sim_mx_alloc(2, [double(regs(2)) double(regs(3))], 0, 16);
    nf = double(regs(9));
    sim_storeN(h + 80, nf, 8);
    fa = double(regs(10));
    fblk = sim_malloc(nf * 8);
    for f = 1:nf
        sc = mem_strcodes(double(sim_load64(fa + (f - 1) * 8)));
        sblk = sim_malloc(numel(sc) + 1);
        for j = 1:numel(sc)
            mem(sblk + j) = uint8(sc(j));
        end
        mem(sblk + numel(sc) + 1) = uint8(0);
        sim_storeN(fblk + (f - 1) * 8, sblk, 8);
    end
    sim_storeN(h + 88, fblk, 8);
    ne = sim_mx_numel(h);
    dblk = sim_malloc(ne * nf * 8);
    for j = 1:ne * nf
        sim_storeN(dblk + (j - 1) * 8, 0, 8);
    end
    sim_storeN(h + 56, dblk, 8);
    regs(1) = int64(h);
elseif strcmp(nm, 'mxGetNumberOfFields')
    regs(1) = sim_load64(double(regs(2)) + 80);
elseif strcmp(nm, 'mxGetFieldNumber')
    f = sim_mx_findfield(double(regs(2)), mem_strcodes(double(regs(3))));
    regs(1) = int64(f);   % 1-based; -1 when absent (real MATLAB: 0)
elseif strcmp(nm, 'mxGetFieldNameByNumber')
    h = double(regs(2));
    f = double(regs(3));
    nf = double(sim_load64(h + 80));
    if f < 1 || f > nf
        regs(1) = int64(0);
    else
        fblk = double(sim_load64(h + 88));
        regs(1) = sim_load64(fblk + (f - 1) * 8);
    end
elseif strcmp(nm, 'mxGetField') || strcmp(nm, 'mxGetFieldByNumber')
    h = double(regs(2));
    i = double(regs(3));
    if strcmp(nm, 'mxGetField')
        f = sim_mx_findfield(h, mem_strcodes(double(regs(9))));
        if f < 0
            regs(1) = int64(0);
        else
            dblk = double(sim_load64(h + 56));
            ne = sim_mx_numel(h);
            regs(1) = sim_load64(dblk + ((f - 1) * ne + i) * 8);
        end
    else
        f = double(regs(9));
        dblk = double(sim_load64(h + 56));
        ne = sim_mx_numel(h);
        regs(1) = sim_load64(dblk + ((f - 1) * ne + i) * 8);
    end
elseif strcmp(nm, 'mxSetField') || strcmp(nm, 'mxSetFieldByNumber')
    h = double(regs(2));
    i = double(regs(3));
    v = regs(10);   % the value argument IS the field-value handle
    if strcmp(nm, 'mxSetField')
        f = sim_mx_findfield(h, mem_strcodes(double(regs(9))));
        if f < 0
            regs(1) = int64(-1);
        else
            dblk = double(sim_load64(h + 56));
            ne = sim_mx_numel(h);
            sim_storeN(dblk + ((f - 1) * ne + i) * 8, v, 8);
            regs(1) = int64(0);
        end
    else
        f = double(regs(9));
        dblk = double(sim_load64(h + 56));
        ne = sim_mx_numel(h);
        sim_storeN(dblk + ((f - 1) * ne + i) * 8, v, 8);
        regs(1) = int64(0);
    end
elseif strcmp(nm, 'mxIsSparse')
    regs(1) = int64(bitand(double(sim_load64(double(regs(2)) + 16)), 2) == 2);
elseif strcmp(nm, 'mxCreateSparse')
    % header +24 extra: +80 ir, +88 jc, +96 nzmax; pr = the nzmax-value
    % block (8-byte doubles), ir/jc packed 4-byte (mwIndex = int)
    m = double(regs(2)); n = double(regs(3));
    nzmax = double(regs(9)); cf = double(regs(10));
    h = sim_mx_alloc(6, [m n], cf, 24);
    sim_storeN(h + 16, bitor(cf, 2), 8);   % complex bit0 + sparse bit1
    % ir/jc are mwIndex = size_t = 8 bytes (cc_int's int and the real
    % Win64 ABI), so the blocks are 8-byte-packed like the C code indexes
    % them (jc[k] at jc + 8*k)
    pr = sim_malloc(nzmax * 8);
    ir = sim_malloc(nzmax * 8);
    jc = sim_malloc((n + 1) * 8);
    for j = 1:nzmax
        sim_storeN(pr + (j - 1) * 8, 0, 8);
        sim_storeN(ir + (j - 1) * 8, 0, 8);
    end
    for j = 1:n + 1
        sim_storeN(jc + (j - 1) * 8, 0, 8);
    end
    sim_storeN(h + 56, pr, 8);
    sim_storeN(h + 80, ir, 8);
    sim_storeN(h + 88, jc, 8);
    sim_storeN(h + 96, nzmax, 8);
    regs(1) = int64(h);
elseif strcmp(nm, 'mxGetIr')
    regs(1) = sim_load64(double(regs(2)) + 80);
elseif strcmp(nm, 'mxGetJc')
    regs(1) = sim_load64(double(regs(2)) + 88);
elseif strcmp(nm, 'mxGetNzmax')
    regs(1) = sim_load64(double(regs(2)) + 96);
elseif strcmp(nm, 'mxSetIr')
    sim_storeN(double(regs(2)) + 80, sim_load64(double(regs(3))), 8);
    regs(1) = int64(0);
elseif strcmp(nm, 'mxSetJc')
    sim_storeN(double(regs(2)) + 88, sim_load64(double(regs(3))), 8);
    regs(1) = int64(0);
elseif strcmp(nm, 'mexMakeArrayPersistent') || ...
        strcmp(nm, 'mexMakeMemoryPersistent') || strcmp(nm, 'mexAtExit')
    regs(1) = int64(0);   % no-ops: the sim heap is arena-based; at-exit
                          % callbacks are never invoked (no unload)
elseif strcmp(nm, 'mexLock')
    sim_mex_locked = 1;
    regs(1) = int64(0);
elseif strcmp(nm, 'mexUnlock')
    sim_mex_locked = 0;
    regs(1) = int64(0);
elseif strcmp(nm, 'mexIsLocked')
    regs(1) = int64(1 * (sim_mex_locked > 0));
elseif strcmp(nm, 'mexCallMATLAB') || strcmp(nm, 'mexCallMATLABWithTrap')
    % mexCallMATLAB(nlhs, plhs, nrhs, prhs, fname): 5th arg on the stack
    % at [rsp+32] (Win64 shadow space; see printf_arg)
    nlhs = double(regs(2));
    plhsaddr = double(regs(3));
    nrhs = double(regs(9));
    prhsaddr = double(regs(10));
    f5 = double(sim_load64(double(regs(5)) + 32));
    fname = cv_char(mem_strcodes(f5));
    margs = {};
    for k = 1:nrhs
        margs{end+1} = sim_mx2mat(double(sim_load64(prhsaddr + (k - 1) * 8)));
    end
    try
        r = sim_feval_multi(fname, margs, nlhs);
        for k = 1:min(nlhs, numel(r))
            sim_storeN(plhsaddr + (k - 1) * 8, mat2sim(r{k}), 8);
        end
        if strcmp(nm, 'mexCallMATLAB')
            regs(1) = int64(0);
        else
            regs(1) = int64(0);   % WithTrap: NULL = success
        end
    catch
        if strcmp(nm, 'mexCallMATLAB')
            % real mexCallMATLAB never returns on error: raise it
            error(['mexCallMATLAB(' fname ') failed']);
        else
            % WithTrap: a non-NULL handle to a minimal object array
            regs(1) = int64(sim_mx_new(17, [1 1], 0));
        end
    end
elseif strcmp(nm, 'mexEvalString') || strcmp(nm, 'mexEvalStringWithTrap')
    code = cv_char(mem_strcodes(double(regs(2))));
    try
        evalin('base', code);
        regs(1) = int64(0);   % WithTrap: NULL = success
    catch err
        if strcmp(nm, 'mexEvalString')
            error(err.identifier, err.message);   % propagate like the real API
        else
            regs(1) = int64(sim_mx_new(17, [1 1], 0));
        end
    end
elseif strcmp(nm, 'mexGetVariable') || strcmp(nm, 'mexGetVariablePtr')
    nmc = mem_strcodes(double(regs(3)));
    try
        v = evalin('base', cv_char(nmc));
        regs(1) = int64(mat2sim(v));
    catch
        regs(1) = int64(0);   % NULL: not found
    end
elseif strcmp(nm, 'mexPutVariable')
    assignin('base', cv_char(mem_strcodes(double(regs(3)))), ...
             sim_mx2mat(double(regs(9))));
    regs(1) = int64(0);
elseif strcmp(nm, 'mexErrMsgIdAndTxt')
    % Raise a REAL catchable error with the MEX identifier (never returns,
    % like the real API).  The engine propagates it through mex_run to the
    % caller's try/catch; error(id, msg) needs ':' in the id (MATLAB rule)
    % and the corpus keeps messages format-arg-free.
    error(cv_char(mem_strcodes(double(regs(2)))), ...
          cv_char(mem_strcodes(double(regs(3)))));
else
    error(['x86sim: unknown mx function ' nm]);
end
end

function h = sim_mx_new(class_id, dims, complexflag)
% sim_mx_new — allocate an 80-byte mxArray header + its data block.
h = sim_mx_alloc(class_id, dims, complexflag, 0);
end

function h = sim_mx_alloc(class_id, dims, complexflag, extra)
% sim_mx_alloc — raw header with `extra` extra bytes past +80 (sparse
% and struct store their extended fields there).  With extra == 0 the
% data block is allocated: every class gets an 8-byte-slot block except
% the packed integer classes; class 2 (struct) gets none (the struct
% shim owns the field-major handle block).  A complex flag also
% allocates the pi block (mxGetPi on a complex matrix must be writable).
global mem
h = sim_malloc(80 + extra);
sim_storeN(h + 0, 1298231634, 8);          % 'MXAR'
sim_storeN(h + 8, class_id, 8);
sim_storeN(h + 16, double(complexflag), 8);
sim_storeN(h + 24, numel(dims), 8);
for k = 1:3
    if k <= numel(dims)
        d = dims(k);
    else
        d = 1;
    end
    sim_storeN(h + 24 + 8 * k, d, 8);
end
ne = 1;
for k = 1:numel(dims)
    ne = ne * dims(k);
end
pr = 0;
if extra == 0 && ne >= 1 && class_id ~= 2
    es = sim_mx_elsize(class_id);
    if class_id == 3 || class_id == 4
        es = 8;   % char/logical data is read/written at 8-byte strides
    end
    pr = sim_malloc(ne * es);
end
sim_storeN(h + 56, pr, 8);
pi = 0;
if extra == 0 && mod(complexflag, 2) == 1 && class_id ~= 2 && ne >= 1
    es = sim_mx_elsize(class_id);
    if class_id == 3 || class_id == 4
        es = 8;
    end
    pi = sim_malloc(ne * es);
end
sim_storeN(h + 64, pi, 8);
sim_storeN(h + 72, 1, 8);
end

function ne = sim_mx_numel(h)
ne = 1;
for k = 1:3
    ne = ne * double(sim_load64(h + 24 + 8 * k));
end
end

function cname = sim_mx_cname(class_id)
syms = { 'unknown','cell','struct','logical','char','function','double','single',...
         'int8','uint8','int16','uint16','int32','uint32','int64','uint64',...
         'void','object' };
if class_id + 1 <= numel(syms)
    cname = sim_strcodes(syms{class_id + 1});
else
    cname = sim_strcodes('unknown');
end
end

function sz = sim_mx_elsize(class_id)
% the integer classes store packed at their native width; everything else
% keeps an 8-byte slot (doubles, and the char/logical convention).
if class_id == 3 || class_id == 4 || class_id == 8 || class_id == 9
    sz = 1;
elseif class_id == 10 || class_id == 11
    sz = 2;
elseif class_id == 12 || class_id == 13
    sz = 4;
else
    sz = 8;
end
end

function sc = sim_mx_string(h)
% sim_mx_string — the char array / string content of an mxArray as codes.
global mem
pr = double(sim_load64(h + 56));
if pr == 0
    sc = [];
    return;
end
n = sim_mx_numel(h);
sc = zeros(1, n);
for k = 1:n
    sc(k) = double(sim_load64(pr + (k - 1) * 8));
end
end

function h2 = sim_mx_dup(h)
global mem
h2 = sim_mx_new(double(sim_load64(h + 8)), sim_mx_dims(h), ...
                mod(double(sim_load64(h + 16)), 2));
pr = double(sim_load64(h + 56));
pr2 = double(sim_load64(h2 + 56));
ne = sim_mx_numel(h);
for k = 1:ne
    sim_storeN(pr2 + (k - 1) * 8, 0, 8);   % placeholder overwritten below
end
for k = 1:ne
    mem(pr2 + (k - 1) * 8 + 1 : pr2 + (k - 1) * 8 + 8) = ...
        mem(pr + (k - 1) * 8 + 1 : pr + (k - 1) * 8 + 8);
end
end

function ds = sim_mx_dims(h)
ds = zeros(1, 3);
for k = 1:3
    ds(k) = double(sim_load64(h + 24 + 8 * k));
end
end

function v = sim_strcodes(str)
% sim_strcodes — 'abc' -> [a b c] code vector (no NUL)
v = double(str);
end

function sim_mx_deepcopy(h, h2)
end

function d = sim_bytes2d(addr)
% sim_bytes2d — build a double VALUE from the 8 bytes at addr (IEEE
% little-endian), via small integer parts only (exact in the clone).
global mem
b0 = double(mem(addr + 1));
b1 = double(mem(addr + 2));
b2 = double(mem(addr + 3));
b3 = double(mem(addr + 4));
b4 = double(mem(addr + 5));
b5 = double(mem(addr + 6));
b6 = double(mem(addr + 7));
b7 = double(mem(addr + 8));
sgn = 1;
if b7 >= 128
    sgn = -1;
    b7 = b7 - 128;
end
expo = b7 * 16 + floor(b6 / 16);
mant = mod(b6, 16) * 2^48 + b5 * 2^40 + b4 * 2^32 + b3 * 2^24 + ...
       b2 * 2^16 + b1 * 2^8 + b0;
if expo == 2047
    if mant == 0
        d = sgn * Inf;
    else
        d = NaN;
    end
elseif expo == 0
    d = sgn * mant * 2^-1074;
else
    d = sgn * (1 + mant * 2^-52) * 2^(expo - 1023);
end
end

function sim_d2bytes(d, addr)
% sim_d2bytes — store the double VALUE d as 8 IEEE little-endian bytes at
% addr, via small integer parts only (exact in the clone).
global mem
if isnan(d)
    bs = [0, 0, 0, 0, 0, 0, 248, 127];   % canonical +NaN bytes
    for k = 1:8
        mem(addr + k) = uint8(bs(k));
    end
    return;
end
sgn7 = 0;
if isnan(d) || isinf(d) || d == 0 || d < 0
    % handled below via the general path (isnan/0 handled first)
end
if isinf(d)
    if d > 0
        bs = [0, 0, 0, 0, 0, 0, 240, 127];
    else
        bs = [0, 0, 0, 0, 0, 0, 240, 255];
    end
    for k = 1:8
        mem(addr + k) = uint8(bs(k));
    end
    return;
elseif d == 0
    if 1 / d < 0
        bs = [0, 0, 0, 0, 0, 0, 0, 128];
    else
        bs = [0, 0, 0, 0, 0, 0, 0, 0];
    end
    for k = 1:8
        mem(addr + k) = uint8(bs(k));
    end
    return;
end
if d < 0
    sgn7 = 128;
    d = -d;
end
e = floor(log2(d));   % d<1 needs floor (fix truncates toward 0)
if e < -1022
    mant = d / 2^-1074;
    expo = 0;
else
    f = d / 2^e;
    mant = round((f - 1) * 2^52);
    expo = e + 1023;
end
b0 = mod(mant, 256);
b1 = mod(floor(mant / 2^8), 256);
b2 = mod(floor(mant / 2^16), 256);
b3 = mod(floor(mant / 2^24), 256);
b4 = mod(floor(mant / 2^32), 256);
b5 = mod(floor(mant / 2^40), 256);
b6 = mod(expo, 16) * 16 + floor(mant / 2^48);
b7 = sgn7 + floor(expo / 16);
mem(addr + 1) = uint8(b0);
mem(addr + 2) = uint8(b1);
mem(addr + 3) = uint8(b2);
mem(addr + 4) = uint8(b3);
mem(addr + 5) = uint8(b4);
mem(addr + 6) = uint8(b5);
mem(addr + 7) = uint8(b6);
mem(addr + 8) = uint8(b7);
end

function r = sim_load64(addr)
% sim_load64 — exact little-endian int64 load.  The byte terms are summed
% in int64 (exact while the running total stays below 2^63); when the top
% byte carries the sign bit (pattern >= 2^63), the low 63 bits are summed
% separately and the value is (magnitude + int64min), staying above
% int64min without ever forming the unrepresentable 2^63.
global mem
b7 = double(mem(addr + 8));
if b7 < 128
    r = int64(0);
    for k = 0:7
        r = r + int64(mem(addr + k + 1)) * int64(2)^(8 * k);
    end
else
    mag = int64(0);
    for k = 0:6
        mag = mag + int64(mem(addr + k + 1)) * int64(2)^(8 * k);
    end
    mag = mag + int64(b7 - 128) * int64(2)^56;
    r = mag + int64(-9223372036854775808);   % set the sign bit
end
end

function sim_storeN(addr, v, nbytes)
global mem
a = double(addr);
% byte extraction via double-domain powers of two: exact for any value
% that is exactly representable as a double (IEEE patterns whose mantissa
% is sparse round-trip exactly; the clone's int64 bit ops are lossy
% above 2^53 and cannot be used here).
vv = double(v);
for k = 0:nbytes-1
    mem(a + k + 1) = uint8(mod(floor(vv / 2^(8 * k)), 256));
end
end

function sim_store_bytes(addr, vals)
global mem
a = double(addr);
for k = 1:numel(vals)
    mem(a + k) = uint8(mod(vals(k), 256));
end
end

% --------------------------------------------------------------------------
function sim_libcall(namecodes)
global regs mem fids simdone xmms
if cv_eq(namecodes, cv_of('printf'))
    fmt = mem_strcodes(double(regs(2)));
    n = sim_printf(fmt, regs(3), regs(9), regs(10));
    regs(1) = int64(n);
elseif cv_eq(namecodes, cv_of('malloc')) || cv_eq(namecodes, cv_of('mxMalloc'))
    sz = double(regs(2));
    regs(1) = int64(sim_malloc(sz));
elseif cv_eq(namecodes, cv_of('mxCalloc'))
    n = double(regs(2)); sz = double(regs(3));
    a = sim_malloc(n * sz);
    for k = 0:n * sz - 1
        mem(a + k + 1) = uint8(0);
    end
    regs(1) = int64(a);
elseif cv_eq(namecodes, cv_of('memset'))
    dst = double(regs(2)); val = double(regs(3)); cnt = double(regs(9));
    for k = 0:cnt-1
        mem(dst + k + 1) = uint8(mod(val, 256));
    end
    regs(1) = int64(dst);
elseif cv_eq(namecodes, cv_of('memcmp'))
    s1 = double(regs(2)); s2 = double(regs(3)); cnt = double(regs(9));
    res = 0;
    for k = 0:cnt-1
        x = double(mem(s1 + k + 1));
        y = double(mem(s2 + k + 1));
        if x ~= y
            res = x - y;
            break;
        end
    end
    regs(1) = int64(res);
elseif cv_eq(namecodes, cv_of('exit'))
    regs(1) = int64(regs(2));
    simdone = 1;
elseif cv_eq(namecodes, cv_of('_open'))
    p = double(regs(2)); flags = double(regs(3));
    regs(1) = int64(sim_open(p, flags));
elseif cv_eq(namecodes, cv_of('_read'))
    fd = double(regs(2)); buf = double(regs(3)); cnt = double(regs(9));
    regs(1) = int64(sim_read(fd, buf, cnt));
elseif cv_eq(namecodes, cv_of('_close'))
    fd = double(regs(2));
    regs(1) = int64(sim_close(fd));
elseif cv_eq(namecodes, cv_of('matOpen'))
    p = double(regs(2)); mp = double(regs(3));
    fname = cv_char(mem_strcodes(p));
    modec = cv_char(mem_strcodes(mp));
    global sim_mat
    if isempty(sim_mat), sim_mat = struct(); end
    % reuse a store with the same filename (the corpus roundtrips: a
    % close followed by a reopen of the same name sees the variables)
    id = 0;
    nm = '';
    fn = fieldnames(sim_mat);
    for k = 1:numel(fn)
        if strcmp(sim_mat.(fn{k}).filename, fname)
            id = str2double(fn{k}(2:end));
            nm = fn{k};
            break;
        end
    end
    if id == 0
        id = numel(fn) + 1;
        nm = sprintf('m%d', id);
        sim_mat.(nm).filename = fname;
        sim_mat.(nm).vars = struct();
    end
    sim_mat.(nm).mode = modec;
    sim_mat.(nm).iter = 0;
    regs(1) = int64(id);
elseif cv_eq(namecodes, cv_of('matClose'))
    regs(1) = int64(0);   % virtual store: kept for the roundtrip
elseif cv_eq(namecodes, cv_of('matPutVariable'))
    global sim_mat
    mf = double(regs(2));
    nm2 = cv_char(mem_strcodes(double(regs(3))));
    pa = double(regs(9));
    sim_mat.(sprintf('m%d', mf)).vars.(nm2) = sim_mx_dup(pa);
    regs(1) = int64(0);
elseif cv_eq(namecodes, cv_of('matPutVariableAsGlobal'))
    global sim_mat
    mf = double(regs(2));
    nm2 = cv_char(mem_strcodes(double(regs(3))));
    pa = double(regs(9));
    sim_mat.(sprintf('m%d', mf)).vars.(nm2) = sim_mx_dup(pa);
    regs(1) = int64(0);
elseif cv_eq(namecodes, cv_of('matPutString'))
    global sim_mat
    mf = double(regs(2));
    nm2 = cv_char(mem_strcodes(double(regs(3))));
    strp = double(regs(9));
    sc = mem_strcodes(strp);
    h = sim_mx_new(4, [1 max(1, numel(sc))], 0);
    pr = double(sim_load64(h + 56));
    for k = 1:numel(sc)
        sim_storeN(pr + (k - 1) * 8, sc(k), 8);
    end
    sim_mat.(sprintf('m%d', mf)).vars.(nm2) = h;
    regs(1) = int64(0);
elseif cv_eq(namecodes, cv_of('matGetVariable')) || ...
        cv_eq(namecodes, cv_of('matGetVariableInfo'))
    global sim_mat
    mf = double(regs(2));
    nm2 = cv_char(mem_strcodes(double(regs(3))));
    vnm = sprintf('m%d', mf);
    if isfield(sim_mat, vnm) && isfield(sim_mat.(vnm).vars, nm2)
        regs(1) = int64(sim_mx_dup(sim_mat.(vnm).vars.(nm2)));
    else
        regs(1) = int64(0);
    end
elseif cv_eq(namecodes, cv_of('matGetNextVariable')) || ...
        cv_eq(namecodes, cv_of('matGetNextVariableInfo'))
    global sim_mat
    mf = double(regs(2));
    npp = double(regs(3));
    vnm = sprintf('m%d', mf);
    vnames = fieldnames(sim_mat.(vnm).vars);
    it = sim_mat.(vnm).iter + 1;
    sim_mat.(vnm).iter = it;
    if it <= numel(vnames)
        h = sim_mx_dup(sim_mat.(vnm).vars.(vnames{it}));
        sc = double(vnames{it});
        addr = sim_malloc(numel(sc) + 1);
        for k = 1:numel(sc)
            mem(addr + k) = uint8(sc(k));   % C string: bytes
        end
        mem(addr + numel(sc) + 1) = uint8(0);
        sim_storeN(npp, addr, 8);   % *nameptr = addr
        regs(1) = int64(h);
    else
        regs(1) = int64(0);
    end
elseif cv_eq(namecodes, cv_of('matGetDir'))
    global sim_mat
    mf = double(regs(2));
    nump = double(regs(3));
    vnm = sprintf('m%d', mf);
    vnames = fieldnames(sim_mat.(vnm).vars);
    n = numel(vnames);
    sim_storeN(nump, n, 8);        % *num = count (cc_int int = 8-byte)
    ptbl = sim_malloc((n + 1) * 8);
    for k = 1:n
        sc = double(vnames{k});
        addr = sim_malloc(numel(sc) + 1);
        for j = 1:numel(sc)
            mem(addr + j) = uint8(sc(j));   % C string: bytes
        end
        mem(addr + numel(sc) + 1) = uint8(0);
        sim_storeN(ptbl + (k - 1) * 8, addr, 8);
    end
    sim_storeN(ptbl + n * 8, 0, 8);   % NULL terminator
    regs(1) = int64(ptbl);
elseif cv_eq(namecodes, cv_of('matGetString'))
    global sim_mat
    mf = double(regs(2));
    nm2 = cv_char(mem_strcodes(double(regs(3))));
    vnm = sprintf('m%d', mf);
    if isfield(sim_mat, vnm) && isfield(sim_mat.(vnm).vars, nm2)
        h = sim_mat.(vnm).vars.(nm2);
        if double(sim_load64(h + 8)) == 4   % mxCHAR_CLASS
            pr = double(sim_load64(h + 56));
            ne = sim_mx_numel(h);
            addr = sim_malloc(ne + 1);
            for k = 1:ne
                mem(addr + k) = uint8(mod(double(sim_load64(pr + (k - 1) * 8)), 256));
            end
            mem(addr + ne + 1) = uint8(0);
            vals = zeros(1, ne);
    for kk = 1:ne
        vals(kk) = double(sim_load64(pr + (kk - 1) * 8));
    end
            regs(1) = int64(addr);
        else
            regs(1) = int64(0);
        end
    else
        regs(1) = int64(0);
    end
elseif cv_eq(namecodes, cv_of('matDeleteVariable'))
    global sim_mat
    mf = double(regs(2));
    nm2 = cv_char(mem_strcodes(double(regs(3))));
    vnm = sprintf('m%d', mf);
    if isfield(sim_mat, vnm) && isfield(sim_mat.(vnm).vars, nm2)
        sim_mat.(vnm).vars = rmfield(sim_mat.(vnm).vars, nm2);
        regs(1) = int64(0);
    else
        regs(1) = int64(1);
    end
elseif cv_eq(namecodes, cv_of('matGetfp'))
    regs(1) = int64(0);
elseif cv_eq(namecodes, cv_of('matSetQuietErrorsOn'))
    regs(1) = int64(0);
elseif cv_eq(namecodes, cv_of('sin'))
    regs(1) = sim_dmath1(regs(2), 'sin');

elseif cv_eq(namecodes, cv_of('cos'))
    regs(1) = sim_dmath1(regs(2), 'cos');
elseif cv_eq(namecodes, cv_of('tan'))
    regs(1) = sim_dmath1(regs(2), 'tan');
elseif cv_eq(namecodes, cv_of('asin'))
    regs(1) = sim_dmath1(regs(2), 'asin');
elseif cv_eq(namecodes, cv_of('acos'))
    regs(1) = sim_dmath1(regs(2), 'acos');
elseif cv_eq(namecodes, cv_of('atan'))
    regs(1) = sim_dmath1(regs(2), 'atan');
elseif cv_eq(namecodes, cv_of('sinh'))
    regs(1) = sim_dmath1(regs(2), 'sinh');
elseif cv_eq(namecodes, cv_of('cosh'))
    regs(1) = sim_dmath1(regs(2), 'cosh');
elseif cv_eq(namecodes, cv_of('tanh'))
    regs(1) = sim_dmath1(regs(2), 'tanh');
elseif cv_eq(namecodes, cv_of('exp'))
    regs(1) = sim_dmath1(regs(2), 'exp');
elseif cv_eq(namecodes, cv_of('log'))
    regs(1) = sim_dmath1(regs(2), 'log');
elseif cv_eq(namecodes, cv_of('log10'))
    regs(1) = sim_dmath1(regs(2), 'log10');
elseif cv_eq(namecodes, cv_of('sqrt'))
    regs(1) = sim_dmath1(regs(2), 'sqrt');
elseif cv_eq(namecodes, cv_of('fabs'))
    regs(1) = sim_dmath1(regs(2), 'abs');
elseif cv_eq(namecodes, cv_of('floor'))
    regs(1) = sim_dmath1(regs(2), 'floor');
elseif cv_eq(namecodes, cv_of('ceil'))
    regs(1) = sim_dmath1(regs(2), 'ceil');
elseif cv_eq(namecodes, cv_of('trunc'))
    regs(1) = sim_dmath1(regs(2), 'sim_dtrunc');
elseif cv_eq(namecodes, cv_of('round'))
    regs(1) = sim_dmath1(regs(2), 'round');
elseif cv_eq(namecodes, cv_of('cbrt'))
    regs(1) = sim_dmath1(regs(2), 'sim_dcbrt');
elseif cv_eq(namecodes, cv_of('fmod'))
    regs(1) = sim_dmath2(regs(2), regs(3), @sim_dfmod);
elseif cv_eq(namecodes, cv_of('pow'))
    regs(1) = sim_dmath2(regs(2), regs(3), @sim_dpow);
elseif cv_eq(namecodes, cv_of('fmin'))
    regs(1) = sim_dmath2(regs(2), regs(3), @sim_dfmin);
elseif cv_eq(namecodes, cv_of('fmax'))
    regs(1) = sim_dmath2(regs(2), regs(3), @sim_dfmax);
elseif cv_eq(namecodes, cv_of('atan2'))
    regs(1) = sim_dmath2(regs(2), regs(3), @atan2);
elseif namecodes(1) == 109 && (namecodes(2) == 120)   % 'm' 'x' -> mx API
    sim_mx(namecodes);
elseif namecodes(1) == 109 && namecodes(2) == 101 && namecodes(3) == 120  % 'mex'
    sim_mx(namecodes);
elseif cv_eq(namecodes, cv_of('strcmp'))
    a = mem_strcodes(double(regs(2)));
    b = mem_strcodes(double(regs(3)));
    regs(1) = int64(sim_strcmp(a, b));
elseif cv_eq(namecodes, cv_of('strlen'))
    regs(1) = int64(numel(mem_strcodes(double(regs(2)))));
elseif cv_eq(namecodes, cv_of('strcpy'))
    d = double(regs(2)); s2 = double(regs(3));
    sc = mem_strcodes(s2);
    for k = 1:numel(sc)
        mem(d + k) = uint8(sc(k));
    end
    regs(1) = int64(d);
elseif cv_eq(namecodes, cv_of('strncpy'))
    d = double(regs(2)); s2 = double(regs(3)); n = double(regs(9));
    sc = mem_strcodes(s2);
    nc = min(numel(sc), n);
    for k = 1:nc
        mem(d + k) = uint8(sc(k));
    end
    regs(1) = int64(d);
elseif cv_eq(namecodes, cv_of('strncmp'))
    a = mem_strcodes(double(regs(2)));
    b = mem_strcodes(double(regs(3)));
    n = double(regs(9));
    if n < numel(a), a = a(1:n); end
    if n < numel(b), b = b(1:n); end
    regs(1) = int64(sim_strcmp(a, b));
elseif cv_eq(namecodes, cv_of('memcpy'))
    d = double(regs(2)); s2 = double(regs(3)); cnt = double(regs(9));
    for k = 1:cnt
        mem(d + k) = mem(s2 + k);
    end
    regs(1) = int64(d);
elseif cv_eq(namecodes, cv_of('free')) || cv_eq(namecodes, cv_of('mxFree'))
    regs(1) = int64(0);   % the sim heap is arena-based; nothing to free
elseif cv_eq(namecodes, cv_of('strcat'))
    d = double(regs(2)); s2 = double(regs(3));
    scd = mem_strcodes(d);
    scs = mem_strcodes(s2);
    n = numel(scd);                     % d length (no NUL in the codes)
    for k = 1:numel(scs)
        mem(d + n + k) = uint8(scs(k));
    end
    mem(d + n + numel(scs) + 1) = uint8(0);
    regs(1) = int64(d);
else
    error('x86sim: unknown library function');
end
end

function r = sim_strcmp(a, b)
% C strcmp on two NUL-terminated code vectors (the strings were loaded
% with the terminating NUL; mem_strcodes strips nothing here).
n = min(numel(a), numel(b));
r = 0;
for k = 1:n
    if a(k) ~= b(k)
        r = a(k) - b(k);
        break;
    end
end
if r == 0 && numel(a) ~= numel(b)
    if numel(a) > numel(b)
        r = a(n + 1);          % b at n+1 is the NUL terminator (0)
    else
        r = -b(n + 1);
    end
end
end

function r = sim_dmath1(x, fname)
% sim_dmath1 — a one-argument double intrinsic.  x is the IEEE pattern;
% the result lives in %xmm0 as a VALUE (the compiler reads it there) and
% is also returned as the pattern for %rax.
global xmms
x2 = sim_bits2d(x);
v = feval(fname, x2);
if ~isreal(v)
    v = NaN;
end
xmms(1) = v;
r = sim_d2bits(v);
end

function r = sim_dmath2(x, y, f)
global xmms
x2 = sim_bits2d(x);
y2 = sim_bits2d(y);
v = f(x2, y2);
if ~isreal(v)
    v = NaN;
end
xmms(1) = v;
r = sim_d2bits(v);
end

function d = sim_bits2d(b)
% sim_bits2d — int64 IEEE-754 bit pattern -> double.  Decoded with int64
% bit-shift/and (exact for any 64-bit pattern) rather than through the
% numeric value, because the pattern integer of a dense double needs far
% more than 53 bits and would round as a double.
sgn = 1;
if b < 0
    sgn = -1;
    b = bitand(b, int64(9223372036854775807));   % clear the sign bit
end
expo = double(bitshift(b, -52));
mant = double(bitand(b, int64(4503599627370495)));
if expo == 2047
    if mant == 0
        d = sgn * Inf;
    else
        d = NaN;
    end
elseif expo == 0
    d = sgn * mant * 2^-1074;
else
    d = sgn * (1 + mant * 2^-52) * 2^(expo - 1023);
end
end

function b = sim_d2bits(d)
% sim_d2bits — the IEEE-754 double d as an int64 bit pattern, computed in
% the DOUBLE domain (every power of two is exact; int64/bitor/native
% typecast are all unreliable in the clone above 2^53).
if isnan(d)
    b = int64(9221120237041090560);   % +NaN 0x7FF8000000000000
    return;
elseif isinf(d)
    if d > 0
        b = int64(9218868437227405312);
    else
        b = int64(-4503599627370496); % 0xFFF0000000000000
    end
    return;
elseif d == 0
    if 1 / d < 0
        b = int64(-9223372036854775808);  % -0.0
    else
        b = int64(0);
    end
    return;
end
negbit = 0;
if d < 0
    negbit = 9223372036854775808;
    d = -d;
end
e = floor(log2(d));   % d<1 needs floor (fix truncates toward 0)
if e < -1022
    mant = d / 2^-1074;              % subnormal
    expo = 0;
else
    f = d / 2^e;
    mant = round((f - 1) * 2^52);
    expo = e + 1023;
end
bits = negbit + expo * 2^52 + mant;
if bits >= 9223372036854775808
    bits = bits - 18446744073709551616;   % two's complement
end
b = int64(bits);
end

function v = sim_dtrunc(x)
% C trunc toward zero (verfied: clone fix() is NaN/Inf-safe, same as MATLAB)
v = fix(x);
end

function v = sim_dcbrt(x)
v = sign(x) * abs(x)^(1/3);
end

function v = sim_dfmod(x, y)
% C fmod: x - trunc(x/y)*y, remainder with the dividend's sign
if y == 0 || isnan(x) || isnan(y) || isinf(x)
    v = NaN;
elseif isinf(y)
    if abs(x) < abs(y)
        v = x;
    else
        v = NaN;
    end
else
    v = x - fix(x / y) * y;
end
end

function v = sim_dpow(x, y)
% C pow semantics: NaN for negative base with non-integral exponent
if x < 0 && mod(y, 1) ~= 0
    v = NaN;
elseif x == 0 && y < 0
    v = Inf;
elseif x == 0 && y == 0
    v = 1;
else
    v = x^y;
    if ~isreal(v)
        v = NaN;
    end
end
end

function v = sim_dfmin(x, y)
if isnan(x)
    v = y;
elseif isnan(y)
    v = x;
else
    v = min(x, y);
end
end

function v = sim_dfmax(x, y)
if isnan(x)
    v = y;
elseif isnan(y)
    v = x;
else
    v = max(x, y);
end
end

function addr = sim_malloc(sz)
global MHEAP
MHEAP = MHEAP + mod(-MHEAP, 16);
addr = MHEAP;
MHEAP = MHEAP + max(sz, 8);
end

function ax = sim_open(p, flags)
global fids
path = cv_char(mem_strcodes(p));
if flags == 1
    mode = 'w';
elseif flags == 2
    mode = 'r+';
else
    mode = 'r';
end
fid = fopen(path, mode);
if fid < 0
    ax = -1;
    return;
end
nf = numel(fieldnames(fids)) + 1;
nm = sprintf('f%d', nf);
fids.(nm) = fid;
ax = nf;
end

function ax = sim_read(fd, baddr, cnt)
global mem fids
nm = sprintf('f%d', fd);
if ~isfield(fids, nm)
    ax = -1;
    return;
end
fid = fids.(nm);
data = fread(fid, cnt, 'uint8');
for k = 1:numel(data)
    mem(baddr + k) = uint8(data(k));
end
ax = numel(data);
end

function ax = sim_close(fd)
global fids
nm = sprintf('f%d', fd);
if ~isfield(fids, nm)
    ax = -1;
    return;
end
fclose(fids.(nm));
fids = rmfield(fids, nm);
ax = 0;
end

% --------------------------------------------------------------------------
function n = sim_printf(fmt, a2, a3, a4)
% sim_printf — the corpus formats (%d %i %u %x %X %o %c %s %p %n %%, flags,
% width incl. *, precision). fmt is a code vector; args a2..a4 are rdx/r8/
% r9 and the rest come from the stack at [rsp+32+8k].
global regs mem
argvals = [a2, a3, a4];
out = [];
ai = 0;
nf = numel(fmt);
i = 1;
while i <= nf
    if fmt(i) ~= 37          % '%'
        out(end+1) = fmt(i);
        i = i + 1;
        continue;
    end
    j = i + 1;
    if j <= nf && fmt(j) == 37
        out(end+1) = 37;
        i = j + 1;
        continue;
    end
    left = 0; zero = 0;
    while j <= nf && (fmt(j) == 45 || fmt(j) == 43 || fmt(j) == 48 || ...
          fmt(j) == 35 || fmt(j) == 32)
        if fmt(j) == 45
            left = 1;
        elseif fmt(j) == 48
            zero = 1;
        end
        j = j + 1;
    end
    w = 0;
    while j <= nf && fmt(j) >= 48 && fmt(j) <= 57
        w = w * 10 + (fmt(j) - 48);
        j = j + 1;
    end
    if j <= nf && fmt(j) == 42   % '*'
        w = printf_arg(argvals, ai);
        ai = ai + 1;
        if w < 0
            left = 1;
            w = -w;
        end
        j = j + 1;
    end
    prec = -1;
    if j <= nf && fmt(j) == 46
        j = j + 1;
        prec = 0;
        while j <= nf && fmt(j) >= 48 && fmt(j) <= 57
            prec = prec * 10 + (fmt(j) - 48);
            j = j + 1;
        end
        if j <= nf && fmt(j) == 42
            prec = printf_arg(argvals, ai);
            ai = ai + 1;
            j = j + 1;
        end
    end
    if j > nf
        out(end+1) = 37;
        break;
    end
    conv = fmt(j);
    av = printf_arg(argvals, ai);
    ai = ai + 1;
    if conv == 115             % 's'
        s = mem_strcodes(double(av));
        if prec >= 0 && numel(s) > prec
            s = s(1:prec);
        end
        txt = pad_cv(s, w, left, 0);
    elseif conv == 99           % 'c'
        txt = mod(double(av), 256);
        if numel(txt) < w
            if left
                txt = [txt, 32 * ones(1, w - numel(txt))];
            else
                txt = [32 * ones(1, w - numel(txt)), txt];
            end
        end
    elseif conv == 100 || conv == 105    % d i
        txt = fmt_int(double(av), w, prec, left, zero);
    elseif conv == 117          % u
        txt = fmt_int(mod(double(av), 18446744073709551616), w, prec, left, zero);
    elseif conv == 120 || conv == 88     % x X
        txt = sim_hex(mod(double(av), 18446744073709551616), 16);
        if conv == 88
            txt = txt - 32 * (txt >= 97);   % uppercase
        end
        txt = strip0c(txt);
        txt = pad_cv(txt, w, left, zero);
    elseif conv == 111          % o
        txt = sim_oct(mod(double(av), 18446744073709551616));
        txt = pad_cv(txt, w, left, zero);
    elseif conv == 112          % p
        txt = sim_hex(mod(double(av), 18446744073709551616), 16);
        txt = pad_cv(txt, w, left, zero);
    elseif conv == 102 || conv == 101 || conv == 103   % f e g
        dv = sim_bits2d(av);   % the int64 bit pattern

        if conv == 101
            fs = 'e';
        elseif conv == 103
            fs = 'g';
        else
            fs = 'f';
        end
        fmt2 = '%';
        if left
            fmt2 = [fmt2, '-'];
        end
        if zero
            fmt2 = [fmt2, '0'];
        end
        if w > 0
            fmt2 = [fmt2, sprintf('%d', w)];
        end
        if conv == 103
            p2 = prec;
            if p2 < 0
                p2 = 6;             % C default: 6 significant digits
            end
            fmt2 = [fmt2, sprintf('.%d', p2), fs];
        elseif prec >= 0
            fmt2 = [fmt2, sprintf('.%d', prec), fs];
        else
            fmt2 = [fmt2, fs];      % C default: 6 fractional digits
        end
        txt = sprintf(fmt2, dv);
        txt = strrep(txt, 'NaN', 'nan');   % glibc-consistent case
        txt = strrep(txt, 'Inf', 'inf');
        txt = double(txt);
    elseif conv == 110          % n
        sim_storeN(double(av), numel(out), 8);
        txt = [];
    else
        txt = [conv, 32];
    end
    out = [out, txt];
    i = j + 1;
end
fprintf('%s', cv_char(out));
n = numel(out);
end

function v = printf_arg(argvals, ai)
global regs mem
if ai < 3
    v = argvals(ai + 1);          % int64 (raw bit pattern for doubles)
else
    k = ai - 3;
    v = sim_load64(double(regs(5)) + 32 + 8 * k);
end
end

function t = fmt_int(v, w, prec, left, zero)
sgn = [];
if v < 0
    s = sim_decstr(-v);
    sgn = 45;                  % '-'
else
    s = sim_decstr(v);
end
if prec >= 0
    while numel(s) < prec
        s = [48, s];
    end
    zero = 0;
end
if zero && ~left
    while numel(s) + numel(sgn) < w
        s = [48, s];           % zeros BETWEEN the sign and the digits
    end
    zero = 0;
end
t = pad_cv([sgn, s], w, left, zero);
end

function t = pad_cv(s, w, left, zero)
if numel(s) >= w
    t = s;
    return;
end
if zero && ~left
    t = [48 * ones(1, w - numel(s)), s];
else
    if left
        t = [s, 32 * ones(1, w - numel(s))];
    else
        t = [32 * ones(1, w - numel(s)), s];
    end
end
end

function t = sim_decstr(v)
% sim_decstr — the full decimal digits of a value. (The clone's
% num2str(v, '%.0f') ignores the format and prints %g — scientific past
% ~1e5 — so large %d/%u values came out as e.g. 9.8765e+08.)
v = double(v);
if v < 0
    sgn = 45;                  % '-'
    v = -v;
else
    sgn = [];
end
if v == 0
    t = [sgn, 48];
    return;
end
digits = [];
while v > 0
    digits = [mod(v, 10), digits];
    v = floor(v / 10);
end
t = [sgn, digits + 48];
end

function t = strip0c(s)
k = 1;
while k < numel(s) && s(k) == 48
    k = k + 1;
end
t = s(k:end);
end

function t = sim_hex(v, n)
t = [];
for k = n-1:-1:0
    d = mod(floor(v / 2^(4 * k)), 16);
    if d < 10
        t(end+1) = d + 48;
    else
        t(end+1) = d + 87;
    end
end
end

function t = sim_oct(v)
t = [];
while v > 0
    t = [mod(v, 8) + 48, t];
    v = floor(v / 8);
end
if isempty(t)
    t = 48;
end
end

% --------------------------------------------------------------------------
% ---- code-vector helpers ----
function t = cv_of(s)
% cv_of — the code vector of a string literal (in the main workspace the
% literal is intact; helpers only ever receive/return double vectors).
t = double(s);
end

function t = cv_char(v)
% cv_char — build a char from a code vector for display/fopen (the clone
% renders these correctly even when the codes look odd internally).
t = char(v);
end

function eq = cv_eq(a, b)
eq = (numel(a) == numel(b)) && all(a == b);
end

function idx = cl_get(name)
global clnames clvals
idx = -1;
for k = 1:numel(clnames)
    if cv_eq(clnames{k}, name)
        idx = clvals(k);
        return;
    end
end
end

function ad = sym_get(name)
global symnames symvals
ad = -1;
for k = 1:numel(symnames)
    if cv_eq(symnames{k}, name)
        ad = symvals(k);
        return;
    end
end
end

% --------------------------------------------------------------------------
function lines = sim_strsplit(s)
% sim_strsplit — split a code vector on newlines (10/13) into trimmed
% code-vector lines.
lines = {};
n = numel(s);
i = 1;
while i <= n
    j = i;
    while j <= n && s(j) ~= 10 && s(j) ~= 13
        j = j + 1;
    end
    L = sim_trim(cv_slice(s, i, j-1));
    if ~isempty(L)
        lines{end+1} = L;
    end
    i = j + 1;
end
end

function t = cv_slice(s, a, b)
% cv_slice — a double-vector slice (safe in local functions).
t = s(a:b);
end

function t = sim_trim(s)
n = numel(s);
a = 1;
while a <= n && (s(a) == 32 || s(a) == 9)
    a = a + 1;
end
b = n;
while b >= a && (s(b) == 32 || s(b) == 9)
    b = b - 1;
end
t = s(a:b);
end

function [d, rest] = sim_split_first(L)
d = [];
rest = [];
n = numel(L);
i = 1;
while i <= n && (L(i) == 32 || L(i) == 9)
    i = i + 1;
end
while i <= n && L(i) ~= 32 && L(i) ~= 9
    d(end+1) = L(i);
    i = i + 1;
end
while i <= n && (L(i) == 32 || L(i) == 9)
    i = i + 1;
end
if i <= n
    rest = L(i:end);
end
end

function parts = sim_split_commas(s)
parts = {};
n = numel(s);
i = 1;
while i <= n
    j = i;
    while j <= n && s(j) ~= 44
        j = j + 1;
    end
    parts{end+1} = s(i:j-1);
    i = j + 1;
end
end

function t = sim_unescape(s)
% s = ".string "hi\n"" codes after the directive keyword.
n = numel(s);
if n >= 1 && s(1) == 34 && s(end) == 34
    s = s(2:end-1);
end
t = [];
i = 1;
while i <= numel(s)
    if s(i) == 92 && i < numel(s)      % '\'
        c = s(i+1);
        if c == 110
            t(end+1) = 10;
        elseif c == 116
            t(end+1) = 9;
        else
            t(end+1) = c;
        end
        i = i + 2;
    else
        t(end+1) = s(i);
        i = i + 1;
    end
end
end

function pos = sim_find(s, c)
pos = [];
for k = 1:numel(s)
    if s(k) == c
        pos(end+1) = k;
    end
end
end

% --------------------------------------------------------------------------
function insn = sim_parse_insn(L)
% parse a code-vector instruction line into {m, op1, op2} with m an opcode
% index (see the table in sim_exec).
[m, rest] = sim_split_first(L);
if isempty(rest)
    % no-operand instruction (ret, cqto, ...): map the mnemonic itself.
    % A hard {0,{0},{0}} made 'ret' execute as a movq with empty operands
    % (the C runtime only masked this through CRLF/NUL file accidents).
    insn = {sim_mnemonic(m), {0}, {0}};
    return;
end
parts = sim_split_ops(rest);
insn = {sim_mnemonic(m), sim_parse_op(sim_trim(parts{1})), {0}};
if numel(parts) >= 2
    insn{3} = sim_parse_op(sim_trim(parts{2}));
end
end

function parts = sim_split_ops(s)
% split operands on the OUTER commas only (ignore commas inside parens).
parts = {};
depth = 0;
start = 1;
for k = 1:numel(s)
    if s(k) == 40
        depth = depth + 1;
    elseif s(k) == 41
        depth = depth - 1;
    elseif s(k) == 44 && depth == 0
        parts{end+1} = s(start:k-1);
        start = k + 1;
    end
end
parts{end+1} = s(start:end);
end

function m = sim_mnemonic(d)
% d = the mnemonic as a code vector -> an opcode index.
%
% The 65-entry table is built ONCE (persistent global).  The previous
% per-call rebuild (75x cv_of + up to 75x cv_eq, each a ~1ms user-function
% call in the clone) cost ~150ms per instruction line in pass 1; this
% version uses builtins only (numel/all inline), prefilters on length +
% first char, and is ordered by corpus frequency so the common mnemonics
% (movq, pushq, leaq, ...) match in the first few iterations.
global sim_mn_codes sim_mn_lens sim_mn_c1 sim_mn_ops
if isempty(sim_mn_ops)
    names = {'movq','pushq','leaq','popq','addq','call','movsd','imulq','subq', ...
             'cmpq','jmp','ret','andq','xorl','je','movzbl','sete','setl', ...
             'movabsq','mulsd','cvtsi2sdq','subsd','jne','setne','addsd', ...
             'divsd','setg','setge','seta','setle','ucomisd','andb','cqto', ...
             'cvttsd2siq','divq','idivq','incq','ja','jae','jb','jbe','jg', ...
             'jge','jl','jle','jnz','jz','movb','movl','movsbl','movw','movzwl', ...
             'negq','notq','orq','sarq','setae','setb','setbe','setnp','shlq', ...
             'shrq','testb','xorpd','xorq'};
    ops = [0 6 5 7 8 37 50 10 9 18 28 38 11 1 29 2 22 24 0 53 56 52 30 23 ...
           51 54 26 27 41 25 58 60 20 57 45 21 16 46 48 47 49 33 34 31 32 ...
           36 35 4 1 3 66 65 14 15 12 39 43 40 42 59 17 44 19 55 13];
    nt = numel(names);
    sim_mn_codes = cell(1, nt);
    sim_mn_lens = zeros(1, nt);
    sim_mn_c1 = zeros(1, nt);
    for k = 1:nt
        t = double(names{k});
        sim_mn_codes{k} = t;
        sim_mn_lens(k) = numel(t);
        sim_mn_c1(k) = t(1);
    end
    sim_mn_ops = ops;
end
m = 99;
ld = numel(d);
c1 = d(1);
lens = sim_mn_lens; c1s = sim_mn_c1; codes = sim_mn_codes; ops = sim_mn_ops;
for k = 1:65
    if lens(k) == ld && c1s(k) == c1 && all(d == codes{k})
        m = ops(k);
        return;
    end
end
end

function op = sim_parse_op(s)
% s = a code vector operand -> {kind, ...}:
%   1 imm {1, val}       2 reg {2, idx, bits}
%   3 mem {3, disp, baseidx, offidx, symaddr, baseoff}
%   6 sym {6, namecodes, resolved}   7 regtarget {7, addr, idx}
if isempty(s)
    op = {0};
    return;
end
if numel(s) >= 2 && s(1) == 42 && s(2) == 37       % '*%rax'
    op = {7, sim_regidx(s(2:end))};
    return;
end
if s(1) == 36                 % '$'
    op = {1, sim_num64(s(2:end))};
    return;
end
if s(1) == 37                 % '%'
    op = {2, sim_regidx(s), sim_regbits(s)};
    return;
end
p1 = sim_find(s, 40);         % '('
if ~isempty(p1)
    op = sim_parse_mem(s, p1(1));
    return;
end
% a bare name (a code label or a library function); resolved at run time
op = {6, s, -1};
end

function op = sim_parse_mem(s, p1)
% mem forms: imm(%rbp) | (%rax) | (%rsi,%rcx) | imm(%rsi,%rcx) | name(%rip)
p2 = sim_find(s, 41);
inside = s(p1+1:p2(1)-1);
parts = sim_split_commas(inside);
op = {3, 0, 0, 0, 0, 0, []};
if numel(parts) >= 1 && ~isempty(parts{1})
    rn = sim_trim(parts{1});
    if rn(1) == 37 && numel(rn) >= 4 && rn(2) == 114 && rn(3) == 105 && rn(4) == 112
        % name(%rip): the disp is the symbol (data or a code label);
        % resolved at run time against the fully-built maps
        op{7} = sim_trim(cv_slice(s, 1, p1-1));
        op{4} = 0;
        return;
    end
    op{3} = sim_regidx(rn);
end
if numel(parts) >= 2 && ~isempty(parts{2})
    op{5} = sim_regidx(parts{2});
end
if p1 > 1
    disp = sim_trim(cv_slice(s, 1, p1-1));
    op{6} = str2double(cv_char(disp));
    op{2} = 0;
else
    op{2} = 0;
    op{6} = 0;
end
end

function v = sim_num64(tok)
% sim_num64 parse a 64-bit literal EXACTLY. The old double-domain
% accumulator v = v*16 + d rounded the running value as soon as it passed
% 2^53, corrupting every dense double-literal pattern (0.1's
% 0x3FB999999999999A parsed to ...312 instead of ...722). Nibbles are
% folded exactly into an int64, one term at a time like sim_load64, never
% exceeding 2^63; a 16-digit pattern's top nibble can set bit 63, so fold
% its low 3 bits and add int64min (exact int64 transport needs the
% MATLAB_in_C v1.3.47+ runtime; older runtimes re-rounded large int64 in
% cell/index reads and writes).
if numel(tok) >= 2 && tok(1) == 48 && (tok(2) == 120 || tok(2) == 88)
    dig = tok(3:end);
    n = numel(dig);
    d15 = 0;
    if n == 16
        c = dig(1);
        if c >= 48 && c <= 57, d15 = c - 48;
        elseif c >= 97 && c <= 102, d15 = c - 87;
        else, d15 = c - 55; end
        dig = dig(2:end);
    end
    mag = int64(0);
    bit = int64(1);
    for k = numel(dig):-1:1
        c = dig(k);
        if c >= 48 && c <= 57, d = c - 48;
        elseif c >= 97 && c <= 102, d = c - 87;
        else, d = c - 55; end
        mag = mag + int64(d) * bit;
        bit = bit * int64(16);
    end
    if n == 16
        P260 = int64(1152921504606846976);   % 2^60
        if d15 >= 8
            mag = mag + int64(d15 - 8) * P260;
            v = mag + int64(-9223372036854775808);   % set bit 63
        else
            v = mag + int64(d15) * P260;
        end
    else
        v = mag;
    end
else
    v = str2double(cv_char(tok));
end
v = int64(v);
end

function idx = sim_regidx(name)
% name = a code vector (e.g. '%rbp', '%al', '%r8d').
% Persistent table + length-prefilter: the previous 40x cv_of rebuild
% cost ~40ms per call in the clone (user-function call overhead), which
% dominated operand parsing in pass 1.
global sim_reg_names sim_reg_lens sim_reg_ops
if isempty(sim_reg_ops)
    rnames = {'rax','rcx','rdx','rbx','rsp','rbp','rsi','rdi', ...
              'al','cl','dl','bl','spl','bpl','sil','dil', ...
              'eax','ecx','edx','ebx','esp','ebp','esi','edi', ...
              'ax','cx','dx','bx','sp','bp','si','di'};
    rops = [1 2 3 4 5 6 7 8 1 2 3 4 5 6 7 8 1 2 3 4 5 6 7 8 1 2 3 4 5 6 7 8];
    rt = numel(rnames);
    sim_reg_names = cell(1, rt);
    sim_reg_lens = zeros(1, rt);
    sim_reg_ops = zeros(1, rt);
    for k = 1:rt
        t = double(rnames{k});
        sim_reg_names{k} = t;
        sim_reg_lens(k) = numel(t);
        sim_reg_ops(k) = rops(k);
    end
end
nm = name;
if nm(1) == 37
    nm = nm(2:end);
end
nn = numel(nm);
if nn >= 3 && nm(1) == 120 && nm(2) == 109 && nm(3) == 109
    % %xmm0..%xmm15: SSE registers -> indices 17..32
    digs = nm(4:nn);
    if isempty(digs)
        error('x86sim: bad xmm register');
    end
    idx = str2double(cv_char(digs)) + 17;
    return;
end
if nn >= 2 && nm(1) == 114 && nm(2) >= 48 && nm(2) <= 57
    digs = nm(2:nn);
    while numel(digs) >= 1 && (digs(end) == 98 || digs(end) == 119 || ...
          digs(end) == 100)
        digs = digs(1:end-1);
    end
    idx = str2double(cv_char(digs)) + 1;   % r8 -> 9 .. r15 -> 16
    return;
end
idx = -1;
lens = sim_reg_lens; nms = sim_reg_names; ops = sim_reg_ops;
for k = 1:32
    if lens(k) == nn && all(nm == nms{k})
        idx = ops(k);
        return;
    end
end
error('x86sim: unknown register');
end

function bits = sim_regbits(name)
nm = name;
if nm(1) == 37
    nm = nm(2:end);
end
c = nm(end);
if c == 98          % 'b'
    bits = 8;
elseif c == 119     % 'w'
    bits = 16;
elseif c == 100     % 'd'
    bits = 32;
else
    bits = 64;
end
end

function s = mem_strcodes(addr)
% mem_strcodes — the NUL-terminated string at addr as a code vector.
global mem
a = double(addr);
s = [];
k = 0;
while true
    c = double(mem(a + k + 1));
    if c == 0
        break;
    end
    s(end+1) = c;
    k = k + 1;
end
end

% --------------------------------------------------------------------------
% sim_mx2mat / mat2sim — the sim-memory <-> MATLAB-value converters.
% Numeric matrices are stored COLUMN-MAJOR (like MATLAB and the clone's
% real_data), so C code using classic i + j*m indexing behaves identically
% on the gcc and oracle tracks.
% --------------------------------------------------------------------------
function v = sim_mx2mat(h)
% sim_mx2mat — convert an in-sim mxArray handle to a MATLAB value.
global mem
if h == 0
    v = [];
    return;
end
cls = double(sim_load64(h + 8));
flags = double(sim_load64(h + 16));
d1 = double(sim_load64(h + 32));

d2 = double(sim_load64(h + 40));
d3 = double(sim_load64(h + 48));
pr = double(sim_load64(h + 56));
ne = d1 * d2 * d3;
if cls == 1
    c = cell(d1, d2);
    for k = 1:ne
        eh = double(sim_load64(pr + (k - 1) * 8));
        c{k} = sim_mx2mat(eh);
    end
    v = c;
elseif cls == 2
    nf = double(sim_load64(h + 80));
    fblk = double(sim_load64(h + 88));
    fn = cell(1, nf);
    for f = 1:nf
        fn{f} = cv_char(mem_strcodes(double(sim_load64(fblk + (f - 1) * 8))));
    end
    if ne == 1
        s = struct();
        for f = 1:nf
            s.(fn{f}) = sim_mx2mat(double(sim_load64(pr + (f - 1) * ne * 8)));
        end
        v = s;
    else
        c = cell(1, ne);
        for k = 1:ne
            s = struct();
            for f = 1:nf
                s.(fn{f}) = sim_mx2mat(double(sim_load64(pr + ((f - 1) * ne + (k - 1)) * 8)));
            end
            c{k} = s;
        end
        v = [c{:}];
    end
elseif cls == 4
    vals = zeros(1, ne);
    for j = 1:ne
        vals(j) = mod(double(sim_load64(pr + (j - 1) * 8)), 256);
    end
    v = char(vals);
elseif cls == 6
    if bitand(flags, 2) == 2
        ir = double(sim_load64(h + 80));
        jc = double(sim_load64(h + 88));
        n = d2;
        nz = double(sim_load64(jc + n * 8));
        ii = zeros(1, nz); jj = zeros(1, nz); vv = zeros(1, nz);
        col = 0;
        for k = 1:nz
            while col < n && double(sim_load64(jc + (col + 1) * 8)) <= k - 1
                col = col + 1;
            end
            ii(k) = double(sim_load64(ir + (k - 1) * 8)) + 1;
            jj(k) = col + 1;
            vv(k) = sim_bytes2d(pr + (k - 1) * 8);
        end
        v = sparse(ii, jj, vv, d1, d2);
        if mod(flags, 2) == 1
            pi = double(sim_load64(h + 64));
            iv = zeros(1, nz);
            for k = 1:nz
                iv(k) = sim_bytes2d(pi + (k - 1) * 8);
            end
            v = v + 1i * sparse(ii, jj, iv, d1, d2);
        end
    else
        vals = zeros(1, ne);
        for j = 1:ne
            vals(j) = sim_bytes2d(pr + (j - 1) * 8);
        end
        if ne == 1
            v = vals;
        else
            % column-major memory (MATLAB-native): M(i,j) = vals((j-1)*d1+i)
            M = zeros(d1, d2);
            for jj = 1:d2
                for ii = 1:d1
                    M(ii, jj) = vals((jj - 1) * d1 + ii);
                end
            end
            v = M;
        end
        if mod(flags, 2) == 1
            pi = double(sim_load64(h + 64));
            vals = zeros(1, ne);
            for j = 1:ne
                vals(j) = sim_bytes2d(pi + (j - 1) * 8);
            end
            if ne == 1
                v = v + 1i * vals;
            else
                Mi = zeros(d1, d2);
                for jj = 1:d2
                    for ii = 1:d1
                        Mi(ii, jj) = vals((jj - 1) * d1 + ii);
                    end
                end
                v = v + 1i * Mi;
            end
        end
    end
elseif cls >= 8 && cls <= 15
    w = sim_mx_elsize(cls);
    vals = zeros(1, ne);
    for j = 1:ne
        vals(j) = mod(double(sim_load64(pr + (j - 1) * w)), 2^(8 * w));
    end
    switch cls
        case 8, v = int8(vals);
        case 9, v = uint8(vals);
        case 10, v = int16(vals);
        case 11, v = uint16(vals);
        case 12, v = int32(vals);
        case 13, v = uint32(vals);
        case 14, v = int64(vals);
        case 15, v = uint64(vals);
    end
else
    v = [];
end
end

function h = mat2sim(v)
% mat2sim — convert a MATLAB value to an in-sim mxArray handle.
global mem
if ischar(v)
    % convert to a DOUBLE code vector FIRST: the clone auto-calls a
    % string INDEX v(j) when v matches a function name ('sin'(j) =
    % sin(j)), so never index the raw char (double vectors are inert)
    codes = double(v);
    h = sim_mx_new(4, [1 max(1, numel(codes))], 0);
    pr = double(sim_load64(h + 56));
    for j = 1:numel(codes)
        sim_storeN(pr + (j - 1) * 8, codes(j), 8);
    end
elseif issparse(v)
    [m n] = size(v);
    [i j s] = find(v);
    nz = numel(i);
    h = sim_mx_new(6, [m n], 0);
    sim_storeN(h + 16, 2, 8);   % sparse flag
    ir = sim_malloc(nz * 8);
    jc = sim_malloc((n + 1) * 8);
    pr = sim_malloc(nz * 8);
    cnt = zeros(1, n + 1);
    for k = 1:nz
        cnt(j(k)) = cnt(j(k)) + 1;   % column j(k) (1-based)
    end
    % jc[k] = # nonzeros in columns 1..k (0-based index k); jc[0] = 0
    sim_storeN(jc, 0, 8);
    acc = 0;
    for c = 1:n
        acc = acc + cnt(c);
        sim_storeN(jc + c * 8, acc, 8);
    end
    for k = 1:nz
        sim_storeN(ir + (k - 1) * 8, i(k) - 1, 8);
        sim_d2bytes(s(k), pr + (k - 1) * 8);
    end

    sim_storeN(h + 56, pr, 8);
    sim_storeN(h + 80, ir, 8);
    sim_storeN(h + 88, jc, 8);
    sim_storeN(h + 96, nz, 8);
elseif iscell(v)
    d1 = size(v, 1); d2 = size(v, 2);
    h = sim_mx_new(1, [d1 d2], 0);
    pr = double(sim_load64(h + 56));
    cnt = 0;
    for ii = 1:d1
        for jj = 1:d2
            cnt = cnt + 1;
            sim_storeN(pr + (cnt - 1) * 8, mat2sim(v{ii, jj}), 8);
        end
    end
elseif isstruct(v)
    fn = fieldnames(v);
    nf = numel(fn);
    ne = numel(v);
    d1 = size(v, 1); d2 = size(v, 2);
    h = sim_mx_alloc(2, [d1 d2], 0, 16);
    sim_storeN(h + 80, nf, 8);
    fblk = sim_malloc(nf * 8);
    for f = 1:nf
        sc = double(fn{f});
        sblk = sim_malloc(numel(sc) + 1);
        for j = 1:numel(sc)
            mem(sblk + j) = uint8(sc(j));
        end
        mem(sblk + numel(sc) + 1) = uint8(0);
        sim_storeN(fblk + (f - 1) * 8, sblk, 8);
    end
    sim_storeN(h + 88, fblk, 8);
    dblk = sim_malloc(ne * nf * 8);
    for f = 1:nf
        for k = 1:ne
            sim_storeN(dblk + ((f - 1) * ne + (k - 1)) * 8, ...
                       mat2sim(v(k).(fn{f})), 8);
        end
    end
    sim_storeN(h + 56, dblk, 8);
elseif isnumeric(v) || islogical(v)
    d1 = size(v, 1); d2 = size(v, 2);
    d3 = 1;
    if numel(size(v)) >= 3
        d3 = size(v, 3);
    end
    if isinteger(v)
        if isa(v, 'int8'), cls = 8;
        elseif isa(v, 'uint8'), cls = 9;
        elseif isa(v, 'int16'), cls = 10;
        elseif isa(v, 'uint16'), cls = 11;
        elseif isa(v, 'int32'), cls = 12;
        elseif isa(v, 'uint32'), cls = 13;
        elseif isa(v, 'int64'), cls = 14;
        else cls = 15; end
    else
        cls = 6;
    end
    cf = 0;
    if cls == 6 && ~isreal(v)
        cf = 1;
    end
    h = sim_mx_new(cls, [d1 d2 d3], cf);
    pr = double(sim_load64(h + 56));
    nbytes = sim_mx_elsize(cls);
    cnt = 0;
    for jj = 1:d2
        for ii = 1:d1
            cnt = cnt + 1;
            if cls == 6
                sim_d2bytes(real(v(ii, jj)), pr + (cnt - 1) * 8);
            else
                sim_storeN(pr + (cnt - 1) * nbytes, ...
                           mod(double(v(ii, jj)), 2^(8 * nbytes)), nbytes);
            end
        end
    end
    if cf
        pi = double(sim_load64(h + 64));
        cnt = 0;
        for jj = 1:d2
            for ii = 1:d1
                cnt = cnt + 1;
                sim_d2bytes(imag(v(ii, jj)), pi + (cnt - 1) * 8);
            end
        end
    end
else
    error('x86sim: mat2sim unsupported input type');
end
end

function v = sim_load32(addr)
% sim_load32 — exact little-endian 32-bit load from a raw address
% (packed mwIndex data in sparse ir/jc blocks).
global mem
v = double(mem(addr + 1)) + 256 * double(mem(addr + 2)) + ...
    65536 * double(mem(addr + 3)) + 16777216 * double(mem(addr + 4));
end

function f = sim_mx_findfield(h, nmc)
% sim_mx_findfield — 1-based field index of name nmc in struct h; -1 if
% absent.  The stored field names are NUL-terminated sim strings.
global mem
nf = double(sim_load64(h + 80));
fblk = double(sim_load64(h + 88));
f = -1;
for k = 1:nf
    saddr = double(sim_load64(fblk + (k - 1) * 8));
    if sim_strcmp(mem_strcodes(saddr), nmc) == 0
        f = k;
        return;
    end
end
end

function r = sim_feval_multi(fname, margs, nlhs)
% sim_feval_multi — feval with an explicit output count and EXPLICIT cell
% indexing (the clone's cell EXPANSION margs{:} inside a call corrupts the
% args and the [c{:}] = feval(...) lhs form is unsupported, so branch per
% arg count and per nlhs; margs{k} indexing is safe).
n = numel(margs);
if nlhs == 1
    if n == 1
        r = {feval(fname, margs{1})};
    elseif n == 2
        r = {feval(fname, margs{1}, margs{2})};
    elseif n == 3
        r = {feval(fname, margs{1}, margs{2}, margs{3})};
    else
        r = {feval(fname)};
    end
elseif nlhs == 2
    if n == 1
        [a, b] = feval(fname, margs{1});
    else
        [a, b] = feval(fname, margs{1}, margs{2});
    end
    r = {a, b};
elseif nlhs == 3
    [a, b, c] = feval(fname, margs{1}, margs{2}, margs{3});
    r = {a, b, c};
elseif nlhs == 4
    [a, b, c, d] = feval(fname, margs{1}, margs{2}, margs{3}, margs{4});
    r = {a, b, c, d};
else
    r = {feval(fname, margs{1})};
end
end
