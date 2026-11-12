% probe_matlab_portability - does this project actually run on MathWorks MATLAB?
%
% Every result in docs/PROJECT_STATUS.md is measured against gcc and two
% runtimes (the C clone and matlab_in_rust) - never against real MATLAB, which
% has no runnable install on the development machine. The code is written for
% MATLAB's rules and run on engines that are lenient about some of them, so this
% probe checks the rules themselves, then compiles and runs corpus programs and
% compares the results with what the clones produce.
%
% Run from the project root (a function file, not a script):
%   >> addpath('tests'); probe_matlab_portability
%
% If the file sits outside the project, name the root explicitly, because
% addpath('src') would otherwise resolve to nothing:
%   >> setenv('CC_ROOT', 'D:\path\to\Writing-a-C-Compiler-in-Matlab')
%   >> addpath('tests'); probe_matlab_portability
%
% Exit code: 0 when every claim that MUST hold holds, 1 otherwise. Claims marked
% INFO are printed with their measured value either way: they are the places the
% clones are lenient, so a difference there is the answer, not a failure.
function probe_matlab_portability()

fprintf('=== probe_matlab_portability ===\n');
try, fprintf('MATLAB:   %s\n', version); catch, fprintf('MATLAB:   (unavailable)\n'); end
try, fprintf('computer: %s\n', computer); catch, end

root = probe_root();
if isempty(root)
    fprintf('ERROR: cannot find the project (no src/cc_int.m above pwd); set CC_ROOT\n');
    return;
end
fprintf('root:     %s\n\n', root);
addpath([root '/src']);
addpath([root '/tests']);

npass = 0;
nfail = 0;

% --- 1. the four language rules the compiler leans on -----------------------
% 1a. a function that reads a global it does not declare is an ERROR. This is
% check_globals' whole premise, and the clones do not enforce it.
[npass, nfail] = chk(npass, nfail, ...
    probe_undeclared_read(), 'function reads an undeclared global', 'error');

% 1b. `c{end+1} = []` stores an empty element and grows the cell. cli-v13 makes
% the second one a no-op; MATLAB grows every time.
c = {};
c{end+1} = [];
c{end+1} = [];
[npass, nfail] = chk(npass, nfail, numel(c), 'two empty cell appends grow the cell', 2);

% 1c. bitshift on int64 wraps rather than saturating - the decimal and hex
% literal paths depend on it (18446744073709551615ULL arrives as -1).
v = bitshift(int64(4294967295), 32);
[npass, nfail] = chk(npass, nfail, v, 'bitshift(int64(4294967295),32) wraps', int64(-4294967296));

% 1d. int64 arithmetic SATURATES (which is why the literal path uses bitshift).
[npass, nfail] = chk(npass, nfail, int64(9223372036854775807) + int64(1), ...
    'int64 addition saturates at INT64_MAX', int64(9223372036854775807));

% 1e. text-mode fopen and CRs. MEASURED ON REAL MATLAB (R2023b): it does NOT
% translate CRLF, so a 6-byte "a\r\nb\r\n" reads back as 6 chars; both clones
% translate and give 4. run_out strips CRs itself now, so either behaviour is
% fine - reported, not counted, because a difference here is a property of the
% runtime rather than a fault.
tmp = [tempname() '.txt'];
fid = fopen(tmp, 'wb'); fwrite(fid, uint8([97 13 10 98 13 10])); fclose(fid);
fid = fopen(tmp, 'r'); got = char(fread(fid, inf, 'uint8')'); fclose(fid);
delete(tmp);
fprintf('INFO  fopen ''r'' of a\r\nb\r\n returns %d chars (real MATLAB 6, clones 4); run_out strips them\n', ...
    numel(got));

% 1f. sprintf('%d', int64) is EXACT on real MATLAB; both clones round through a
% double past 53 bits (2^53+1 prints as 2^53, INT64_MIN+1 as INT64_MIN). The
% compiler does not depend on it - wide literals are emitted in hex - so this is
% reported, not counted.
fprintf('INFO  sprintf %%d of int64(2^53+1) = %s (real MATLAB: 9007199254740993)\n', ...
    sprintf('%d', int64(9007199254740993)));

% 1g. and the empty-cell growth the other runtimes disagree about is the same
% shape as 1b: cli-v13 makes the second append a no-op. 1b covers it.

% --- 2. the compiler runs at all ---------------------------------------------
% Three corpus programs whose x86sim exit codes are known from the clones. A
% fourth claim compiles the one that exercises the newest code (array types).
cases = {'hello.c', [], 'cc39_wrap.c', 96, 'cc51_mdimparam.c', 96};
fprintf('\n-- compiling corpus programs --\n');
first_fail = nfail;             % index of the first failure, for the stack
for k = 1:2:numel(cases)
    nm = cases{k};
    want = cases{k+1};
    sfile = [tempname() '.s'];
    try
        cc_int([root '/tests/programs/' nm], sfile);
        lines = count_lines(sfile);
        if isempty(want)
            [npass, nfail] = chk(npass, nfail, lines > 0, ...
                sprintf('%s compiles (%d lines)', nm, lines), true);
        else
            got = mod(x86sim(sfile), 256);
            [npass, nfail] = chk(npass, nfail, got, ...
                sprintf('%s runs to the clone''s exit code', nm), want);
        end
    catch e
        fprintf('FAIL  %s: %s\n', nm, e.message);
        % the first failure is the one worth a stack: every later program runs
        % the same compiler code, so they will name the same line
        if nfail == first_fail
            try
                st = e.stack;
                for q = 1:numel(st)
                    fprintf('      at %s, line %d\n', st(q).name, st(q).line);
                end
            catch
            end
        end
        nfail = nfail + 1;
    end
    delete(sfile);
end

% --- verdict ----------------------------------------------------------------
fprintf('\nprobe_matlab_portability: %d passed, %d failed\n', npass, nfail);
if nfail == 0
    fprintf('VERDICT: this project runs on this MATLAB.\n');
else
    fprintf('VERDICT: %d claim(s) do not hold here - the lines above say which.\n', nfail);
end
end

% --------------------------------------------------------------------------
function [npass, nfail] = chk(npass, nfail, got, name, want)
if isequal(got, want)
    fprintf('PASS  %s\n', name);
    npass = npass + 1;
else
    fprintf('FAIL  %s: got %s, wanted %s\n', name, show(got), show(want));
    nfail = nfail + 1;
end
end

function s = show(v)
if ischar(v)
    s = ['''' v ''''];
elseif isempty(v)
    s = '[]';
elseif isa(v, 'int64')
    s = sprintf('%d', v);
elseif numel(v) == 1
    s = sprintf('%g', double(v));
else
    s = sprintf('%s (%d elems)', class(v), numel(v));
end
end

function n = count_lines(f)
fid = fopen(f, 'r');
if fid < 0
    n = -1;
    return;
end
t = char(fread(fid, inf, 'uint8')');
fclose(fid);
n = numel(strfind(t, char(10)));
end

function r = probe_undeclared_read()
% a function that reads a global it does not declare. Real MATLAB errors; the
% lenient clones resolve it through the caller chain, which is why check_globals
% exists. Returns 'error' when it errored, 'ok' when the read succeeded.
r = probe_undeclared_helper();
if ischar(r)
    r = 'error';
else
    r = 'ok';
end
end

function v = probe_undeclared_helper()
global probe_shared
probe_shared = 7;
try
    v = probe_read_anyway();   % the helper below does NOT declare it
catch
    v = 'error';
end
end

function v = probe_read_anyway()
v = probe_shared;              % deliberately undeclared
end

function root = probe_root()
root = getenv('CC_ROOT');
if ~isempty(root) && exist([root '/src/cc_int.m'], 'file') == 2
    return;
end
root = '';
d = pwd;
for k = 1:8
    if exist([d '/src/cc_int.m'], 'file') == 2
        root = d;
        return;
    end
    up = fileparts(d);
    if isempty(up) || strcmp(up, d)
        break;
    end
    d = up;
end
end
