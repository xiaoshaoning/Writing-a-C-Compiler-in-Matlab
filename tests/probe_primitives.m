function [npass, nfail] = probe_primitives()
% probe_primitives — gate for the runtime primitives the xc port depends on.
% Targets the MATLAB clone v1.2.38 (2026-08-10 bug-report fixes verified on
% it); every check also passes on real MATLAB R2023b.
% Prints PASS/FAIL lines; returns pass/fail counts for the test harness.
% Run from the project root via tests/run_tests.m (this is a function file).

npass = 0;
nfail = 0;

% --- typed arrays: element + slice assignment, incl. converted arrays
%     (BUG-1 fixed in v1.2.38) ---
m = zeros(1, 16, 'uint8');
m(3) = 7;
[npass nfail] = addcheck(npass, nfail, m(3) == 7, 'uint8 element assign');

m(2:5) = zeros(1, 4, 'uint8') + [1 2 3 4];
[npass nfail] = addcheck(npass, nfail, isequal(double(m(2:5)), [1 2 3 4]), ...
                         'uint8 slice assign');

z = uint8([5 6 7]);
z(2) = 9;
[npass nfail] = addcheck(npass, nfail, isequal(double(z), [5 9 7]), ...
                         'converted uint8 assign (BUG-1)');

w = zeros(1, 4, 'int64');
w(2) = 300;
[npass nfail] = addcheck(npass, nfail, double(w(2)) == 300, 'int64 element assign');

% --- word load/store round-trip (byte decomposition via mod + typecast).
%     load8 mirrors xc.m word_load: direct typecast of the slice (BUG-7) ---
mem = zeros(1, 64, 'uint8');
vals = [0, 1, -1, 300, -300, 2^40, -2^40, 2^53 - 1];
for v = vals
    mem = store8(mem, 8, int64(v));
    got = double(load8(mem, 8));
    [npass nfail] = addcheck(npass, nfail, got == v, ...
                             sprintf('word round-trip %d', v));
end

% slicing a typed array keeps the type; direct typecast decodes (BUG-7)
s = mem(9:16);
[npass nfail] = addcheck(npass, nfail, strcmp(class(s), 'uint8'), ...
                         'slice keeps uint8 type (BUG-7)');
[npass nfail] = addcheck(npass, nfail, ...
                         double(typecast(s, 'int64')) == 2^53 - 1, ...
                         'direct slice typecast (BUG-7)');

% --- mod on int64; returns double on the clone (DIV-7) but exact for
%     |x| < 2^53, which is all word_store needs ---
[npass nfail] = addcheck(npass, nfail, double(mod(int64(300), int64(256))) == 44, ...
                         'mod(int64, int64)');
[npass nfail] = addcheck(npass, nfail, double(mod(int64(-1), int64(256))) == 255, ...
                         'mod negative int64');

% --- int64 arithmetic shift right (BUG-11, fixed in v1.2.39) ---
[npass nfail] = addcheck(npass, nfail, double(bitshift(int64(-16), -1)) == -8, ...
                         'bitshift(i64,-1) arithmetic (BUG-11)');
[npass nfail] = addcheck(npass, nfail, double(bitshift(int64(-16), -2)) == -4, ...
                         'bitshift(i64,-2) arithmetic (BUG-11)');

% --- stepped colon stop-on-wrong-side is empty (DIV-8, fixed v1.2.39) ---
[npass nfail] = addcheck(npass, nfail, numel(1:2:0) == 0, ...
                         '1:2:0 empty (DIV-8)');
[npass nfail] = addcheck(npass, nfail, isequal(1:2:4, [1 3]), ...
                         '1:2:4 unchanged (DIV-8)');

% --- align8 formula (independent check of xc's helper math) ---
a8 = [0 1 7 8 9 16];
e8 = [0 8 8 8 16 16];
[npass nfail] = addcheck(npass, nfail, isequal(a8 + mod(-a8, 8), e8), ...
                         'align8 formula');

% --- global shared across functions; a local-function call nested in
%     another call's argument list works (BUG-8 fixed in v1.2.38) ---
gset(7);
[npass nfail] = addcheck(npass, nfail, gget() == 7, 'global shared across functions');
gset(-3);
[npass nfail] = addcheck(npass, nfail, gget() == -3, 'global persists across calls');

% --- zero-arg varargin is empty (BUG-9 fixed) ---
[npass nfail] = addcheck(npass, nfail, vcount() == 0, 'zero-arg varargin (BUG-9)');

% --- cell element deletion removes the element (BUG-10 fixed) ---
c = {'-s', 'file.c'};
c(1) = [];
[npass nfail] = addcheck(npass, nfail, numel(c) == 1 && strcmp(c{1}, 'file.c'), ...
                         'cell deletion removes (BUG-10)');

% --- fopen missing file returns -1 ---
fid = fopen('tests/programs/_does_not_exist.c', 'r');
[npass nfail] = addcheck(npass, nfail, fid == -1, 'fopen missing file returns -1');
if fid >= 0
    fclose(fid);
end

% --- source loading: fread('uint8') + char (plain fread reads double units) ---
tf = 'tests/_probe_tmp.txt';
fid = fopen(tf, 'w');
fprintf(fid, 'abc123\nsecond line\n');
fclose(fid);
fid = fopen(tf, 'r');
s = char(fread(fid, inf, 'uint8')');
fclose(fid);
[npass nfail] = addcheck(npass, nfail, ischar(s) && ...
                         ~isempty(strfind(s, 'abc123')) && ...
                         ~isempty(strfind(s, 'second line')), ...
                         'fread+char source loading');
% note: delete() silently no-ops on the clone — the temp file is left behind

% --- evalc captures fprintf (harness requirement) ---
try
    s2 = evalc('fprintf(''hello %d\n'', 42)');
    [npass nfail] = addcheck(npass, nfail, ~isempty(strfind(s2, 'hello 42')), ...
                             'evalc captures fprintf');
catch e
    [npass nfail] = addcheck(npass, nfail, false, ...
                             sprintf('evalc captures fprintf: %s', e.message));
end

fprintf('probe_primitives: %d passed, %d failed\n', npass, nfail);

% ---------------------------------------------------------------------------
function [npass, nfail] = addcheck(npass, nfail, cond, name)
if cond
    fprintf('PASS  %s\n', name);
    npass = npass + 1;
else
    fprintf('FAIL  %s\n', name);
    nfail = nfail + 1;
end
end

function m = store8(m, a, v64)
% independent re-implementation of xc's word_store byte decomposition
v64 = int64(v64);
for k = 0:7
    b = mod(v64, int64(256));
    m(a+k+1) = uint8(b);
    v64 = int64((v64 - b) / int64(256));
end
end

function v = load8(m, a)
% mirrors xc.m word_load: direct typecast of the uint8 slice (BUG-7 fixed)
v = typecast(m(a+1:a+8), 'int64');
end

function gset(v)
global GX_PROBE
GX_PROBE = v;
end

function v = gget()
global GX_PROBE
v = GX_PROBE;
end

function n = vcount(varargin)
n = numel(varargin);
end
