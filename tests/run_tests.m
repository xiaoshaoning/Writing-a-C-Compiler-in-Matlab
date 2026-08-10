% run_tests — xc.m test harness.
%
% Run from the project root:
%   matlab.bat tests/run_tests.m
% or:
%   matlab.bat -batch "addpath('.'); addpath('tests'); run_tests"
%
% Exits non-zero if any test fails.

addpath('.');
addpath('tests');

npass = 0;
nfail = 0;

% --- group 1: runtime primitives gate ---
[p, f] = probe_primitives();
npass = npass + p;
nfail = nfail + f;

% --- group 2: xc.m scaffold behavior ---
% usage error
try
    xc();
    [npass nfail] = addcheck(npass, nfail, false, 'xc() with no args errors');
catch e
    [npass nfail] = addcheck(npass, nfail, ...
                             ~isempty(strfind(e.message, 'usage')), ...
                             'xc() usage error');
end

% missing file
try
    xc('tests/programs/_does_not_exist.c');
    [npass nfail] = addcheck(npass, nfail, false, 'xc(missing file) errors');
catch e
    [npass nfail] = addcheck(npass, nfail, ...
                             ~isempty(strfind(e.message, 'could not open')), ...
                             'xc() missing-file error');
end

% valid source: scaffold reports pipeline not yet implemented
try
    xc('tests/programs/return_2.c');
    [npass nfail] = addcheck(npass, nfail, false, ...
                             'xc(source) hits pipeline-not-implemented');
catch e
    [npass nfail] = addcheck(npass, nfail, ...
                             ~isempty(strfind(e.message, 'not implemented')), ...
                             'xc(source) scaffold error');
end

% -s flag parses and source still loads
try
    xc('-s', 'tests/programs/return_2.c');
    [npass nfail] = addcheck(npass, nfail, false, ...
                             'xc(-s, source) hits pipeline-not-implemented');
catch e
    [npass nfail] = addcheck(npass, nfail, ...
                             ~isempty(strfind(e.message, 'not implemented')), ...
                             'xc(-s) flag parse + source load');
end

% --- group 3: Phase 1 VM selftest (38-opcode eval) ---
try
    rc = xc('--vm-selftest');
    [npass nfail] = addcheck(npass, nfail, rc == 0, ...
                             'xc --vm-selftest (38-op VM)');
catch e
    [npass nfail] = addcheck(npass, nfail, false, ...
                             sprintf('xc --vm-selftest: %s', e.message));
end

% --- group 4: Phase 2 lexer selftest + -s dump format ---
try
    out = evalc('rc = xc(''--lex-selftest'')');
    fprintf('%s', out);   % keep per-case PASS/FAIL + dump lines visible
    [npass nfail] = addcheck(npass, nfail, rc == 0, 'xc --lex-selftest (lexer)');
    [npass nfail] = addcheck(npass, nfail, ...
                             ~isempty(strfind(out, '1: int x;')), ...
                             'xc -s line dump format');
catch e
    [npass nfail] = addcheck(npass, nfail, false, ...
                             sprintf('xc --lex-selftest: %s', e.message));
end

fprintf('run_tests: %d tests, %d passed, %d failed\n', npass + nfail, npass, nfail);
if nfail > 0
    error(sprintf('run_tests: %d failures', nfail));
end

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
