% probe_globinit2 - confirm or refute, under real MATLAB, that the consumer's
% pp_globinit2 failure is engine-specific.
%
% Run from the project root (this is a function file, not a script):
%   >> addpath('tests'); probe_globinit2
%
% If the probe file does not sit inside the project (it is copied elsewhere),
% give it the root explicitly - otherwise it stops with an ERROR, because
% addpath('src') would silently resolve to a 'src' that does not exist:
%   >> setenv('CC_ROOT', 'D:\path\to\Writing-a-C-Compiler-in-Matlab')
%   >> addpath('tests'); probe_globinit2
%
% Background: on matlab-cli (v8 and v11) compiling tests/programs/pp_globinit2.c
% writes an assembly file in which the line
%
%       <tab>call<tab>f
%
% arrives as SEVEN separate lines, one character each, so `as` rejects it with
% "Error: no such instruction: `c'". The same compiler and the same program on
% the C clone emit one line and the file assembles and runs (exit 42).
%
% The claims this checks:
%
%   C  baseline shapes: the line builds as a 1x7 row, and assigning such a row
%      into a cell appends ONE cell.
%   D  the ginit capture pattern - save a global cell, rebind it, append from a
%      nested function, restore - neither loses nor splits entries. This is the
%      one context the engine-side reproductions could not clear.
%   A  numel(out) after the compile is 45 (the C clone's count), not 51.
%   B  the call line is ONE cell of 1x7 chars and no cell is a single character.
%   B2 the line is intact in the written file, and B3 the file assembles.
%
% If C, D, A and B all pass, the consumer's code is correct under real MATLAB
% and the failure is matlab-cli-specific.

function probe_globinit2()

fprintf('=== probe_globinit2 ===\n');
try, fprintf('MATLAB: %s\n', version); catch, fprintf('MATLAB: (version unavailable)\n'); end
try, fprintf('computer: %s\n', computer); catch, end
if exist('OCTAVE_VERSION', 'builtin')
    fprintf('NOTE: this is Octave, not MATLAB\n');
end
fprintf('\n');

here = fileparts(mfilename('fullpath'));
% Find the project root. The probe may be run from anywhere (or copied
% elsewhere), so try the file's parent directory first, then the current
% directory, then CC_ROOT. Fail loudly rather than letting addpath('src')
% resolve to a 'src' that does not exist.
old = pwd;
cands = {fullfile(fileparts(here), ''), pwd, getenv('CC_ROOT')};
root = '';
for k = 1:numel(cands)
    c = cands{k};
    if isempty(c)
        continue;
    end
    if exist(fullfile(c, 'src', 'cc_int.m'), 'file') == 2
        root = c;
        break;
    end
end
if isempty(root)
    fprintf('\nERROR: cannot find src/cc_int.m.\n');
    fprintf('  Tried: %s\n', strjoin(cands(cellfun(@(x) ~isempty(x), cands)), ', '));
    fprintf('  Run this probe from the project root, or set CC_ROOT:\n');
    fprintf('    >> setenv(''CC_ROOT'', ''D:\\path\\to\\Writing-a-C-Compiler-in-Matlab'')\n');
    fprintf('  Claims C and D above do not need the project; A, B, B2, B3 do.\n');
    return;
end
fprintf('project root: %s\n', root);
cd(root);

% ---------------------------------------------------------------- claim C
fprintf('-- claim C: baseline string and cell shapes\n');
line = sprintf('\tcall\t%s', 'f');
c = {};
c{end+1} = line;
d = {};
d{end+1} = strrep(line, char(9), char(9));
fprintf('   the line built             : size=%s\n', mat2str(size(line)));
fprintf('   that value into a cell     : numel=%d size(c{1})=%s\n', ...
        numel(c), mat2str(size(c{1})));
fprintf('   after a strrep into a cell : numel=%d size(d{1})=%s\n', ...
        numel(d), mat2str(size(d{1})));
fprintf('   the bare literal [call f]: size=%s\n', mat2str(size('call f')));
cC = (numel(c) == 1) && isequal(size(c{1}), [1 7]) && ...
     (numel(d) == 1) && isequal(size(d{1}), [1 7]) && isequal(size(line), [1 7]);
report('C  (a 1x7 row appends one cell)', cC);

% ---------------------------------------------------------------- claim D
fprintf('\n-- claim D: the ginit capture pattern (save / rebind / append / restore)\n');
global PROBE_CELL
PROBE_CELL = {'alpha', 'beta'};
n0 = numel(PROBE_CELL);
sav = PROBE_CELL;
PROBE_CELL = {};
% append the real 7-character line, not a single character: a one-character
% string cannot reveal a split, which is what an earlier version of this probe
% got wrong
nested_append(sprintf('\tcall\t%s', 'f'));
inner = numel(PROBE_CELL);
inner_size = size(PROBE_CELL{1});
PROBE_CELL = sav;
n1 = numel(PROBE_CELL);
% and once more into the restored cell, to check the append still adds one
nested_append('y');
n2 = numel(PROBE_CELL);
fprintf('   before=%d  inner after one append=%d (size=%s)  restored=%d  after one more=%d\n', ...
        n0, inner, mat2str(inner_size), n1, n2);
cD = (inner == 1) && size(inner_size, 1) == 1 && inner_size(2) > 1 && ...
     (n1 == n0) && (n2 == n0 + 1) && ...
     ischar(PROBE_CELL{1}) && strcmp(PROBE_CELL{1}, 'alpha');
report('D  (the capture pattern is sound, even for a 7-char row)', cD);

% ---------------------------------------------------------------- claims A/B
fprintf('\n-- claims A/B: compile pp_globinit2.c and inspect the emitter''s cell\n');
src = fullfile('tests', 'programs', 'pp_globinit2.c');
asm = 'tmp_probe_globinit2.s';
if exist(asm, 'file') == 2
    delete(asm);
end
clear global out
okcompile = true;
try
    addpath('src');
    cc_int(src, asm);
catch err
    okcompile = false;
    fprintf('   cc_int FAILED: %s\n', err.message);
end

if ~okcompile
    fprintf('   the compile did not finish, so claims A and B are untested\n');
else
    global out
    n = numel(out);
    singles = 0;
    callat = 0;
    for k = 1:n
        t = out{k};
        if ischar(t)
            if numel(t) == 1
                singles = singles + 1;
            end
            if callat == 0 && ~isempty(strfind(t, 'call'))
                callat = k;
            end
        end
    end
    fprintf('   numel(out) = %d   single-character cells = %d\n', n, singles);
    if callat
        fprintf('   first cell containing "call": index %d  size=%s  text=[%s]\n', ...
                callat, mat2str(size(out{callat})), ...
                strrep(out{callat}, char(9), '<TAB>'));
    else
        fprintf('   NO cell contains "call"\n');
    end
    report('A  (numel(out) == 45, the C clone count)', n == 45);
    report('B  (the call line is one 1x7 cell, no 1x1 cells)', ...
           singles == 0 && callat > 0 && isequal(size(out{callat}), [1 7]));

    txt = fileread(asm);
    oneline = ~isempty(strfind(txt, [char(9) 'call' char(9) 'f']));
    fprintf('   file: %d bytes, %d newlines, call-line-intact=%d\n', ...
            numel(txt), numel(strfind(txt, char(10))), oneline);
    report('B2 (the call line is intact in the file)', oneline);

    [st, msg] = system('C:\msys64\ucrt64\bin\gcc.exe tmp_probe_globinit2.s -o tmp_probe_globinit2.exe');
    fprintf('   gcc on the .s: exit=%d\n', st);
    if st ~= 0
        fprintf('   %s\n', strtrim(msg));
    else
        [rst, ~] = system('tmp_probe_globinit2.exe');
        fprintf('   program exit=%d (the C clone gives 42)\n', rst);
    end
    report('B3 (the assembly is accepted)', st == 0);
end

fprintf('\n=== verdict ===\n');
fprintf('If C, D, A, B, B2 and B3 all pass, the consumer is correct under real\n');
fprintf('MATLAB and the pp_globinit2 failure is matlab-cli-specific. Paste this\n');
fprintf('output into docs/NOTE_2026-11-04_pp_globinit2_residual.md as round two.\n');

cd(old);
end

% ------------------------------------------------------------------ helpers

function nested_append(txt)
% a nested function appending to the global cell, like the consumer's em()
global PROBE_CELL
PROBE_CELL{end+1} = strrep(txt, char(9), '<TAB>');
end

function report(name, ok)
if ok
    fprintf('   PASS  %s\n', name);
else
    fprintf('   FAIL  %s\n', name);
end
end
