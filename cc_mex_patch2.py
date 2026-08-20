# -*- coding: utf-8 -*-
# ME-2 part 2: x86sim — the in-memory mxArray ABI + mx/mex stubs.
BS = chr(92); t = BS + 't'
p = 'src/x86sim.m'
s = open(p, encoding='utf-8').read()

# ---- 1) dispatch mx/mex names in sim_libcall ----
old = """elseif cv_eq(namecodes, cv_of('atan2'))
    regs(1) = sim_dmath2(regs(2), regs(3), @atan2);
else
    error('x86sim: unknown library function');
end
end"""
new = """elseif cv_eq(namecodes, cv_of('atan2'))
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
    regs(1) = int64(numel(mem_strcodes(double(regs(2)))) - 1);
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
elseif cv_eq(namecodes, cv_of('free'))
    regs(1) = int64(0);   % the sim heap is arena-based; nothing to free
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
end"""
assert s.count(old) == 1, "mx dispatch"
s = s.replace(old, new)

# ---- 2) the mx stubs (appended before the helpers section marker) ----
anchor = """function d = sim_bytes2d(addr)"""
mx_block = """function sim_mx(namecodes)
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
    h = double(regs(2));
    pr = double(sim_load64(h + 56));
    if pr == 0
        regs(1) = int64(0);
    else
        v = sim_bytes2d(pr);
        regs(1) = int64(isnan(v));
    end
elseif strcmp(nm, 'mxIsInf')
    h = double(regs(2));
    pr = double(sim_load64(h + 56));
    if pr == 0
        regs(1) = int64(0);
    else
        v = sim_bytes2d(pr);
        regs(1) = int64(isinf(v));
    end
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
        mem(dst + k + 1) = uint8(mod(c, 256));
        k = k + 1;
    end
    mem(dst + k + 1) = uint8(0);
    regs(1) = int64(0);
elseif strcmp(nm, 'mxArrayToString')
    sc = sim_mx_string(double(regs(2)));
    if isempty(sc)
        regs(1) = int64(0);
    else
        a = sim_malloc(numel(sc) + 1);
        for k = 1:numel(sc)
            mem(a + k) = uint8(sc(k));
        end
        mem(a + numel(sc) + 1) = uint8(0);
        regs(1) = int64(a);
    end
elseif strcmp(nm, 'mxDuplicateArray')
    regs(1) = int64(sim_mx_dup(double(regs(2))));
elseif strcmp(nm, 'mxDestroyArray')
    regs(1) = int64(0);   % arena heap: no real destructor
elseif strcmp(nm, 'mxSetData')
    sim_storeN(double(regs(2)) + 56, sim_load64(double(regs(3))), 8);
    regs(1) = int64(0);
elseif strcmp(nm, 'mxAssert')
    if double(regs(2)) == 0
        fprintf('Assertion failed\\n');
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
    fprintf('Error using %s\\n', cv_char(mem_strcodes(double(regs(3)))));
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

""" + anchor
assert s.count(anchor) == 1, "anchor"
s = s.replace(anchor, mx_block)

open(p, 'w', encoding='utf-8').write(s)
print("x86sim mx stubs applied; lines:", len(s.split(chr(10))))
PYEOF_MARKER = None