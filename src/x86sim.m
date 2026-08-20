function exit_code = x86sim(sfile)
% x86sim — a mini x86-64 simulator for the assembly emitted by cc_int.m.
%
% Runs the generated .s directly — no assembler, linker, or gcc. Parses
% the COFF-ish directives (ignoring .file/.def/.globl/.cfi), lays out
% .comm/.data/.string symbols in a byte memory, and interprets the
% instruction stream with a register file, flags, and a downward-growing
% stack. Emulates the CRT entry (call main; the exit code = rax) and the
% runtime-library symbols the shims forward to (printf, malloc, memset,
% memcmp, exit, _open, _read, _close).
%
%   exit_code = x86sim('out.s')     % the program's exit code (full rax;
%                                   % callers truncate to the low byte)
%
% All text is processed as double code vectors: the clone mangles certain
% string literals (e.g. 'sum', 'count', 'set') when they cross local-
% function boundaries, so names are compared as code vectors.

global MEMSZ DATA_BASE CODE_BASE STACK_TOP MHEAP
global mem symnames symvals clnames clvals code regs xmms zf sf cf of pf fids simdone
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
cursor = DATA_BASE;
pending = {};                  % {addr, nbytes, value-or-labelcodes}
mode = 'text';
plab = [];                     % a pending label awaiting data/code resolution
for li = 1:numel(lines)
    L = lines{li};
    if L(end) == 58 && isempty(sim_find(L, 9))      % ':' label, no tab
        lab = cv_slice(L, 1, numel(L)-1);
        if strcmp(mode, 'data')
            symnames{end+1} = lab;
            symvals(end+1) = cursor;
        elseif ~(numel(lab) >= 3 && lab(1) == 46 && lab(2) == 76 && lab(3) == 70)
            % not a .LF marker: resolve any pending label (a label followed
            % by a label in the text section is a code label), then hold
            % the new one pending for the next item
            if ~isempty(plab)
                clnames{end+1} = plab;
                clvals(end+1) = numel(code) + 1;
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
                symnames{end+1} = plab;
                symvals(end+1) = cursor;
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
            symnames{end+1} = nm;
            symvals(end+1) = cursor;
            cursor = cursor + sz;
        elseif cv_eq(d, cv_of('.quad')) || cv_eq(d, cv_of('.byte'))
            if ~isempty(plab)
                symnames{end+1} = plab;
                symvals(end+1) = cursor;
                plab = [];
            end
            nb = 8;
            if cv_eq(d, cv_of('.byte'))
                nb = 1;
            end
            parts = sim_split_commas(rest);
            for k = 1:numel(parts)
                p = sim_trim(parts{k});
                if ~isempty(p) && p(1) == 46
                    pending{end+1} = {cursor, nb, p};   % a label reference
                else
                    pending{end+1} = {cursor, nb, sim_num64(p)};
                end
                cursor = cursor + nb;
            end
        elseif cv_eq(d, cv_of('.string'))
            if ~isempty(plab)
                symnames{end+1} = plab;
                symvals(end+1) = cursor;
                plab = [];
            end
            txt = sim_unescape(rest);
            pending{end+1} = {cursor, 1, [double('S'), txt]};
            cursor = cursor + numel(txt) + 1;
        end
        continue;
    end
    if strcmp(mode, 'text')
        if ~isempty(plab)
            clnames{end+1} = plab;
            clvals(end+1) = numel(code) + 1;
            plab = [];
        end
        code{end+1} = sim_parse_insn(L);
    end
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
        sim_store_bytes(e{1}, v);
    end
end

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
while pc >= 1 && pc <= n && simdone == 0
    insn = code{pc};
    pc = sim_exec(insn, pc);
    steps = steps + 1;
    if steps > maxsteps
        error('x86sim: step limit exceeded (possible infinite loop)');
    end
end
exit_code = double(regs(1));
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
    v = mod(sim_opval(a), 4294967296);
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
    c = mod(sim_opval(a), 64);
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
            wf = fopen('D:/tmp/wlog.txt', 'a'); fprintf(wf, 'store mem=%d val=%-6.2f ', sim_effaddr(b), sim_opval(a)); fclose(wf);
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
    wf = fopen('D:/tmp/wlog.txt', 'a'); fprintf(wf, 'uc %.6f %.6f ', xb, xa); fclose(wf);
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
    wf = fopen('D:/tmp/wlog.txt', 'a'); fprintf(wf, 'np z%d c%d p%d ', zf, cf, pf); fclose(wf);
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
global regs xmms mem
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
    dd = fopen('D:/tmp/mxdbg.txt','a'); fprintf(dd,' scal h=%d pr=%d v=%.17g', h, pr, v); fclose(dd);
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
    sim_storeN(double(regs(2)) + 56, sim_load64(double(regs(3))), 8);
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
    n = sim_printf(fmt, double(regs(3)), double(regs(9)), double(regs(10)));
    regs(1) = int64(n);
elseif strcmp(nm, 'mexEvalString')
    regs(1) = int64(0);
elseif strcmp(nm, 'mexErrMsgIdAndTxt')
    % print MATLAB-style and stop: real mexErrMsgIdAndTxt never returns
    fprintf('Error using %s\n', cv_char(mem_strcodes(double(regs(3)))));
    global simdone
    simdone = 1;
    regs(1) = int64(-1);
else
    error(['x86sim: unknown mx function ' nm]);
end
end

function h = sim_mx_new(class_id, dims, complexflag)
% sim_mx_new — allocate an 80-byte mxArray header + its data block.
global mem
h = sim_malloc(80);
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
if ne >= 1
    pr = sim_malloc(ne * 8);
end
sim_storeN(h + 56, pr, 8);
sim_storeN(h + 64, 0, 8);
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
if class_id == 3 || class_id == 4
    sz = 1;
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
    n = sim_printf(fmt, double(regs(3)), double(regs(9)), double(regs(10)));
    regs(1) = int64(n);
elseif cv_eq(namecodes, cv_of('malloc'))
    sz = double(regs(2));
    regs(1) = int64(sim_malloc(sz));
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
    r = a(k) - b(k);
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
if isnan(x) || isinf(x)
    v = x;
else
    v = fix(x);
end
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
    insn = {0, {0}, {0}};
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
m = 99;
p8  = cv_of('movq');  p1 = cv_of('movl');  p2 = cv_of('movzbl');
p3  = cv_of('movsbl'); p4 = cv_of('movb');  p5 = cv_of('leaq');
p6  = cv_of('pushq'); p7 = cv_of('popq');  p8b = cv_of('addq');
p9  = cv_of('subq');  p10 = cv_of('imulq'); p11 = cv_of('andq');
p12 = cv_of('orq');   p13 = cv_of('xorq'); p14 = cv_of('negq');
p15 = cv_of('notq');  p16 = cv_of('incq'); p17 = cv_of('shlq');
p17b= cv_of('sarq');  p18 = cv_of('cmpq'); p19 = cv_of('testb');
p20 = cv_of('cqto');  p21 = cv_of('idivq'); p22 = cv_of('sete');
p23 = cv_of('setne'); p24 = cv_of('setl'); p25 = cv_of('setle');
p26 = cv_of('setg');  p27 = cv_of('setge'); p28 = cv_of('jmp');
p29 = cv_of('je');    p30 = cv_of('jne'); p31 = cv_of('jl');
p32 = cv_of('jle');   p33 = cv_of('jg');  p34 = cv_of('jge');
p35 = cv_of('jz');    p36 = cv_of('jnz'); p37 = cv_of('call');
p38 = cv_of('ret');   px  = cv_of('xorl');
p40 = cv_of('setb');  p41 = cv_of('seta'); p42 = cv_of('setbe');
p43 = cv_of('setae'); p44 = cv_of('shrq'); p45 = cv_of('divq');
p46 = cv_of('ja');    p47 = cv_of('jb');   p48 = cv_of('jae');
p49 = cv_of('jbe');
pm = cv_of('movabsq');
p50 = cv_of('movsd'); p51 = cv_of('addsd'); p52 = cv_of('subsd');
p53 = cv_of('mulsd'); p54 = cv_of('divsd'); p55 = cv_of('xorpd');
p56 = cv_of('cvtsi2sdq'); p57 = cv_of('cvttsd2siq');
p58 = cv_of('ucomisd'); p59 = cv_of('setnp'); p60 = cv_of('andb');
if cv_eq(d, p8) || cv_eq(d, pm)
    m = 0;
elseif cv_eq(d, p1) || cv_eq(d, px)
    m = 1;
elseif cv_eq(d, p2)
    m = 2;
elseif cv_eq(d, p3)
    m = 3;
elseif cv_eq(d, p4)
    m = 4;
elseif cv_eq(d, p5)
    m = 5;
elseif cv_eq(d, p6)
    m = 6;
elseif cv_eq(d, p7)
    m = 7;
elseif cv_eq(d, p8b)
    m = 8;
elseif cv_eq(d, p9)
    m = 9;
elseif cv_eq(d, p10)
    m = 10;
elseif cv_eq(d, p11)
    m = 11;
elseif cv_eq(d, p12)
    m = 12;
elseif cv_eq(d, p13)
    m = 13;
elseif cv_eq(d, p14)
    m = 14;
elseif cv_eq(d, p15)
    m = 15;
elseif cv_eq(d, p16)
    m = 16;
elseif cv_eq(d, p17)
    m = 17;
elseif cv_eq(d, p17b)
    m = 39;
elseif cv_eq(d, p18)
    m = 18;
elseif cv_eq(d, p19)
    m = 19;
elseif cv_eq(d, p20)
    m = 20;
elseif cv_eq(d, p21)
    m = 21;
elseif cv_eq(d, p22)
    m = 22;
elseif cv_eq(d, p23)
    m = 23;
elseif cv_eq(d, p24)
    m = 24;
elseif cv_eq(d, p25)
    m = 25;
elseif cv_eq(d, p26)
    m = 26;
elseif cv_eq(d, p27)
    m = 27;
elseif cv_eq(d, p28)
    m = 28;
elseif cv_eq(d, p29)
    m = 29;
elseif cv_eq(d, p30)
    m = 30;
elseif cv_eq(d, p31)
    m = 31;
elseif cv_eq(d, p32)
    m = 32;
elseif cv_eq(d, p33)
    m = 33;
elseif cv_eq(d, p34)
    m = 34;
elseif cv_eq(d, p35)
    m = 35;
elseif cv_eq(d, p36)
    m = 36;
elseif cv_eq(d, p37)
    m = 37;
elseif cv_eq(d, p38)
    m = 38;
elseif cv_eq(d, p40)
    m = 40;
elseif cv_eq(d, p41)
    m = 41;
elseif cv_eq(d, p42)
    m = 42;
elseif cv_eq(d, p43)
    m = 43;
elseif cv_eq(d, p44)
    m = 44;
elseif cv_eq(d, p45)
    m = 45;
elseif cv_eq(d, p46)
    m = 46;
elseif cv_eq(d, p47)
    m = 47;
elseif cv_eq(d, p48)
    m = 48;
elseif cv_eq(d, p49)
    m = 49;
elseif cv_eq(d, p50)
    m = 50;
elseif cv_eq(d, p51)
    m = 51;
elseif cv_eq(d, p52)
    m = 52;
elseif cv_eq(d, p53)
    m = 53;
elseif cv_eq(d, p54)
    m = 54;
elseif cv_eq(d, p55)
    m = 55;
elseif cv_eq(d, p56)
    m = 56;
elseif cv_eq(d, p57)
    m = 57;
elseif cv_eq(d, p58)
    m = 58;
elseif cv_eq(d, p59)
    m = 59;
elseif cv_eq(d, p60)
    m = 60;
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
% sim_num64 — parse a 64-bit literal EXACTLY (in the double domain: every
% power of two is exact, so hex and in-range decimal patterns round-trip;
% int64 accumulation would overflow through the clone's lossy int64 ops).
if numel(tok) >= 2 && tok(1) == 48 && (tok(2) == 120 || tok(2) == 88)
    v = 0;
    for k = 3:numel(tok)
        c = tok(k);
        if c >= 48 && c <= 57
            d = c - 48;
        elseif c >= 97 && c <= 102
            d = c - 87;
        else
            d = c - 55;
        end
        v = v * 16 + d;
    end
    if v >= 9223372036854775808
        v = v - 18446744073709551616;
    end
else
    v = str2double(cv_char(tok));
end
v = int64(v);
end

function idx = sim_regidx(name)
% name = a code vector (e.g. '%rbp', '%al', '%r8d').
p8  = cv_of('al'); p8b = cv_of('cl'); p8c = cv_of('dl'); p8d = cv_of('bl');
p8e = cv_of('spl'); p8f = cv_of('bpl'); p8g = cv_of('sil'); p8h = cv_of('dil');
p64 = cv_of('rax'); p64b = cv_of('rcx'); p64c = cv_of('rdx'); p64d = cv_of('rbx');
p64e = cv_of('rsp'); p64f = cv_of('rbp'); p64g = cv_of('rsi'); p64h = cv_of('rdi');
p32 = cv_of('eax'); p32b = cv_of('ecx'); p32c = cv_of('edx'); p32d = cv_of('ebx');
p32e = cv_of('esp'); p32f = cv_of('ebp'); p32g = cv_of('esi'); p32h = cv_of('edi');
nm = name;
if nm(1) == 37
    nm = nm(2:end);
end
idx = -1;
if cv_eq(nm, p64) || cv_eq(nm, p8) || cv_eq(nm, p32)
    idx = 1;
elseif cv_eq(nm, p64b) || cv_eq(nm, p8b) || cv_eq(nm, p32b)
    idx = 2;
elseif cv_eq(nm, p64c) || cv_eq(nm, p8c) || cv_eq(nm, p32c)
    idx = 3;
elseif cv_eq(nm, p64d) || cv_eq(nm, p8d) || cv_eq(nm, p32d)
    idx = 4;
elseif cv_eq(nm, p64e) || cv_eq(nm, p8e) || cv_eq(nm, p32e)
    idx = 5;
elseif cv_eq(nm, p64f) || cv_eq(nm, p8f) || cv_eq(nm, p32f)
    idx = 6;
elseif cv_eq(nm, p64g) || cv_eq(nm, p8g) || cv_eq(nm, p32g)
    idx = 7;
elseif cv_eq(nm, p64h) || cv_eq(nm, p8h) || cv_eq(nm, p32h)
    idx = 8;
elseif numel(nm) >= 3 && nm(1) == 120 && nm(2) == 109 && nm(3) == 109
    % %xmm0..%xmm15: SSE registers -> indices 17..32
    digs = nm(4:end);
    if isempty(digs)
        error('x86sim: bad xmm register');
    end
    idx = str2double(cv_char(digs)) + 17;
elseif numel(nm) >= 2 && nm(1) == 114 && nm(2) >= 48 && nm(2) <= 57
    digs = nm(2:end);
    while numel(digs) >= 1 && (digs(end) == 98 || digs(end) == 119 || ...
          digs(end) == 100)
        digs = digs(1:end-1);
    end
    idx = str2double(cv_char(digs)) + 1;   % r8 -> 9 .. r15 -> 16
end
if idx < 0
    error('x86sim: unknown register');
end
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
