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
%   exit_code = x86sim('out.s')     % the program's exit code (low byte)
%
% All text is processed as double code vectors: the clone mangles certain
% string literals (e.g. 'sum', 'count', 'set') when they cross local-
% function boundaries, so names are compared as code vectors.

global MEMSZ DATA_BASE CODE_BASE STACK_TOP MHEAP
global mem symnames symvals clnames clvals code regs zf sf cf of fids simdone
MEMSZ  = 4 * 1024 * 1024;
DATA_BASE = 4096;
CODE_BASE = DATA_BASE + MEMSZ;
STACK_TOP = DATA_BASE + MEMSZ - 16;
MHEAP = DATA_BASE + MEMSZ / 2;
mem = zeros(1, MEMSZ, 'uint8');
symnames = {};  symvals = [];    % data symbol code-vectors -> byte address
clnames = {};   clvals = [];     % code label code-vectors -> instruction index
code = {};
regs = zeros(1, 16, 'int64');
zf = 0; sf = 0; cf = 0; of = 0;
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
                    pending{end+1} = {cursor, nb, str2double(cv_char(p))};
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
global regs code clnames clvals simdone CODE_BASE
m = insn{1};
a = insn{2};
b = insn{3};
next = pc + 1;
if m == 0                % movq
    v = sim_opval(a);
    sim_opstore(b, v, 64);
elseif m == 1            % movl / xorl (32-bit, zero-extends)
    v = mod(sim_opval(a), 4294967296);
    sim_opstore(b, v, 32);
elseif m == 2            % movzbl
    v = mod(sim_opval(a), 256);
    sim_opstore(b, v, 32);
elseif m == 3            % movsbl
    v = mod(sim_opval(a), 256);
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
elseif m == 39           % sarq
    c = mod(sim_opval(a), 64);
    sim_opstore(b, bitshift(sim_opval(b), -c, 'int64'), 64);
elseif m == 18           % cmpq
    sim_setflags_cmp(sim_opval(b), sim_opval(a));
elseif m == 19           % testb
    r = bitand(mod(sim_opval(b), 256), mod(sim_opval(a), 256), 'int64');
    sim_setflags_alu(r);
elseif m == 20           % cqto
    if regs(1) < 0
        regs(3) = int64(-1);
    else
        regs(3) = int64(0);
    end
elseif m == 21           % idivq
    dv = sim_opval(a);
    if dv == 0
        error('x86sim: division by zero');
    end
    q = fix(double(regs(1)) / double(dv));
    r = double(regs(1)) - q * double(dv);
    regs(1) = int64(q);
    regs(3) = int64(r);
elseif m >= 22 && m <= 27   % sete setne setl setle setg setge
    sim_opstore(a, sim_jcc(m - 22), 8);
elseif m >= 28 && m <= 36   % jmp je jne jl jle jg jge jz jnz
    if m == 28 || sim_jcc(m - 29)
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
else
    error('x86sim: unsupported instruction');
end
pc = next;
end

function t = sim_jcc(k)
% k: 0 sete/je/jz, 1 setne/jne/jnz, 2 setl/jl, 3 setle/jle, 4 setg/jg,
% 5 setge/jge, 6 jz, 7 jnz
global zf sf of
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
else
    t = (sf == of);            % setge/jge
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
if a{4} > 0                      % a resolved symbol address
    ad = a{4};
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

function sim_setflags_cmp(d, s)
global zf sf cf of
d = double(d); s = double(s);
r = d - s;
zf = (r == 0);
sf = (r < 0);
cf = (mod(d, 4294967296) < mod(s, 4294967296));
of = 0;
if (d < 0 && s >= 0 && r >= 0) || (d >= 0 && s < 0 && r < 0)
    of = 1;
end
end

% --------------------------------------------------------------------------
function sim_regwrite(idx, bits, v)
global regs
if bits == 64
    regs(idx) = int64(v);
elseif bits == 32
    regs(idx) = int64(mod(double(v), 4294967296));
elseif bits == 16
    cur = double(regs(idx));
    regs(idx) = int64(cur - mod(cur, 65536) + mod(double(v), 65536));
else
    cur = double(regs(idx));
    regs(idx) = int64(cur - mod(cur, 256) + mod(double(v), 256));
end
end

function v = sim_regread(idx, bits)
global regs
r = double(regs(idx));
if bits == 8
    v = mod(r, 256);
elseif bits == 16
    v = mod(r, 65536);
elseif bits == 32
    v = mod(r, 4294967296);
else
    v = r;
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

function r = sim_load64(addr)
global mem
a = double(addr);
lo = int64(0);
for k = 0:3
    lo = lo + int64(mem(a + k + 1)) * int64(2)^(8 * k);
end
hi = int64(0);
for k = 4:7
    hi = hi + int64(mem(a + k + 1)) * int64(2)^(8 * (k - 4));
end
if hi >= int64(2)^31
    r = (hi - int64(2)^32) * int64(2)^32 + lo;
else
    r = hi * int64(2)^32 + lo;
end
end

function sim_storeN(addr, v, nbytes)
global mem
a = double(addr);
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
global regs mem fids simdone
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
else
    error('x86sim: unknown library function');
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
            txt = txt + 32 * (txt >= 97) - 32 * (txt >= 97);
        end
        txt = strip0c(txt);
        txt = pad_cv(txt, w, left, zero);
    elseif conv == 111          % o
        txt = sim_oct(mod(double(av), 18446744073709551616));
        txt = pad_cv(txt, w, left, zero);
    elseif conv == 112          % p
        txt = sim_hex(mod(double(av), 18446744073709551616), 16);
        txt = pad_cv(txt, w, left, zero);
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
    v = argvals(ai + 1);
else
    k = ai - 3;
    v = sim_load64(double(regs(5)) + 32 + 8 * k);
end
end

function t = fmt_int(v, w, prec, left, zero)
sgn = [];
if v < 0
    s = cv_of(num2str(-v, '%.0f'));
    sgn = 45;                  % '-'
else
    s = cv_of(num2str(v, '%.0f'));
end
if prec >= 0
    while numel(s) < prec
        s = [48, s];
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
if cv_eq(d, p8)
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
    op = {1, str2double(cv_char(s(2:end)))};
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
if isempty(p2)
end
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
