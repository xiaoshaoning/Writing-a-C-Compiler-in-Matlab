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

% -s compiles without executing (returns 0, prints source lines)
try
    out = evalc('rc = xc(''-s'', ''tests/programs/return_2.c'')');
    [npass nfail] = addcheck(npass, nfail, rc == 0, 'xc(-s) compiles, exit 0');
    [npass nfail] = addcheck(npass, nfail, ...
                             ~isempty(strfind(out, '1: int main()')), ...
                             'xc(-s) dumps source lines');
catch e
    [npass nfail] = addcheck(npass, nfail, false, ...
                             sprintf('xc(-s): %s', e.message));
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

% --- group 5: Phase 3 end-to-end programs (compile + eval, exit codes) ---
ptests = {
    'return_2.c',      2;
    'p3_precedence.c', 7;
    'p3_divmod.c',    13;
    'p3_assoc.c',      3;
    'p3_globals.c',   65;
    'p3_globals2.c', 100;
    'p3_ifelse1.c',    1;
    'p3_ifelse2.c',    2;
    'p3_while.c',     45;
    'p3_logic.c',      1;
    'p3_ternary.c',    7;
    'p3_enum.c',       2;
    'p3_sizeof.c',     7;
    'p3_locals.c',    13;
    'p3_incdec.c',     7;
    'p3_postdec.c',    6;
    'p3_unary.c',      7;
    'p3_not.c',       -1;
    'p3_pointer.c',    7;
    'p3_call.c',       5;
};
for k = 1:size(ptests, 1)
    try
        out = evalc(sprintf('rc = xc(''tests/programs/%s'')', ptests{k,1}));
        [npass nfail] = addcheck(npass, nfail, rc == ptests{k,2}, ...
            sprintf('%s -> exit %d', ptests{k,1}, ptests{k,2}));
    catch e
        [npass nfail] = addcheck(npass, nfail, false, ...
            sprintf('%s: %s', ptests{k,1}, e.message));
    end
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
