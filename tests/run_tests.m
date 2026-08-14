% run_tests — xc.m test harness.
%
% Run from the project root:
%   matlab.bat tests/run_tests.m
% or (batch mode — the clone does not resolve a script's local functions when
% the script is run by name after addpath, so invoke the file with run()):
%   matlab.bat -batch "run('tests/run_tests.m');"
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

% --- group 6: Phase 4 functions (recursion, args, shadowing) ---
% Expected exits verified against the reference C build.
ftests = {
    'p4_factorial.c', 120;
    'p4_fib.c',       55;
    'p4_multiarg.c',  10;
    'p4_charparam.c', 67;
    'p4_nested.c',    25;
    'p4_shadow.c',    10;
    'p4_shadowsys.c',  5;
    'p4_charlocal.c', 80;
};
for k = 1:size(ftests, 1)
    try
        out = evalc(sprintf('rc = xc(''tests/programs/%s'')', ftests{k,1}));
        [npass nfail] = addcheck(npass, nfail, rc == ftests{k,2}, ...
            sprintf('%s -> exit %d', ftests{k,1}, ftests{k,2}));
    catch e
        [npass nfail] = addcheck(npass, nfail, false, ...
            sprintf('%s: %s', ftests{k,1}, e.message));
    end
end

% --- group 7: Phase 5 pointers, arrays, casts, bitwise ---
% Expected exits verified against the reference C build.
xtests = {
    'p5_swap.c',    73;
    'p5_ptrslots.c', 10;
    'p5_strwalk.c',  5;
    'p5_strindex.c', 98;
    'p5_ptrptr.c',  42;
    'p5_pindex.c',  60;
    'p5_cast.c',    65;
    'p5_ptridx.c',   6;
    'p5_preinc.c',   6;
    'p5_ptrdiff.c',  1;
    'p5_bitshift.c', 32;
    'p5_postdec.c',  9;
};
for k = 1:size(xtests, 1)
    try
        out = evalc(sprintf('rc = xc(''tests/programs/%s'')', xtests{k,1}));
        [npass nfail] = addcheck(npass, nfail, rc == xtests{k,2}, ...
            sprintf('%s -> exit %d', xtests{k,1}, xtests{k,2}));
    catch e
        [npass nfail] = addcheck(npass, nfail, false, ...
            sprintf('%s: %s', xtests{k,1}, e.message));
    end
end

% --- group 8: Phase 6 syscalls (stdout + exit, verified vs reference) ---
stests = {
    'hello.c',       0, ['fibonacci( 0) = 1' char(10) 'fibonacci( 1) = 1' char(10) ...
                         'fibonacci( 2) = 2' char(10) 'fibonacci( 3) = 3' char(10) ...
                         'fibonacci( 4) = 5' char(10) 'fibonacci( 5) = 8' char(10) ...
                         'fibonacci( 6) = 13' char(10) 'fibonacci( 7) = 21' char(10) ...
                         'fibonacci( 8) = 34' char(10) 'fibonacci( 9) = 55' char(10) ...
                         'fibonacci(10) = 89' char(10) 'exit(0)'];
    'p6_printf.c',  0, ['hello 42 7' char(10) 'exit(0)'];
    'p6_printf2.c', 0, ['[ 5][300][300]' char(10) 'exit(0)'];
    'p6_malloc.c', 42, 'exit(42)';
    'p6_memset.c',  0, 'exit(0)';
    'p6_memcmp.c', -1, 'exit(-1)';
    'p6_exit.c',    3, 'exit(3)';
    'p6_file.c',    0, 'exit(0)';
};
for k = 1:size(stests, 1)
    try
        out = evalc(sprintf('rc = xc(''tests/programs/%s'')', stests{k,1}));
        [npass nfail] = addcheck(npass, nfail, rc == stests{k,2} && ...
                                 strcmp(out, [stests{k,3}]), ...
            sprintf('%s -> exit %d, stdout match', stests{k,1}, stests{k,2}));
    catch e
        [npass nfail] = addcheck(npass, nfail, false, ...
            sprintf('%s: %s', stests{k,1}, e.message));
    end
end

% -d execution trace works end-to-end
try
    out = evalc('rc = xc(''-d'', ''tests/programs/return_2.c'')');
    [npass nfail] = addcheck(npass, nfail, rc == 2, 'xc(-d) traces, exit 2');
    [npass nfail] = addcheck(npass, nfail, ...
                             ~isempty(strfind(out, '> ENT')) && ...
                             ~isempty(strfind(out, '> EXIT')), ...
                             'xc(-d) trace lines');
catch e
    [npass nfail] = addcheck(npass, nfail, false, ...
                             sprintf('xc(-d): %s', e.message));
end

% --- group 9: post-parity features (beyond the reference dialect) ---
ptests9 = {
    'pp_comments.c',  5;
    'pp_array.c',  4321;
    'pp_array2.c',   24;
    'pp_array3.c',    1;
    'pp_array4.c',   25;
    'pp_init.c',    104;
    'pp_init2.c',    95;
    'pp_void.c',      7;
    'pp_mread.c',   406;
};
for k = 1:size(ptests9, 1)
    try
        out = evalc(sprintf('rc = xc(''tests/programs/%s'')', ptests9{k,1}));
        [npass nfail] = addcheck(npass, nfail, rc == ptests9{k,2}, ...
            sprintf('%s -> exit %d', ptests9{k,1}, ptests9{k,2}));
    catch e
        [npass nfail] = addcheck(npass, nfail, false, ...
            sprintf('%s: %s', ptests9{k,1}, e.message));
    end
end
% %s in printf (width preserved) — stdout check
try
    out = evalc('rc = xc(''tests/programs/pp_s.c'')');
    [npass nfail] = addcheck(npass, nfail, rc == 0 && ...
        strcmp(out, ['[abc][x 42][   hi]' char(10) 'exit(0)']), ...
        'pp_s.c %s with width');
catch e
    [npass nfail] = addcheck(npass, nfail, false, ...
        sprintf('pp_s.c: %s', e.message));
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
