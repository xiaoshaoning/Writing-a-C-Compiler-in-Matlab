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
    'pp_addrof.c',   42;
    'pp_addrof2.c',  78;
    'pp_addrof3.c',  34;
    'pp_fdreuse.c',   0;
    'pp_arrinit.c', 789;
    'pp_arrinit2.c', 123;
    'pp_arrinit3.c', 198;
    'pp_arrinit4.c', 195;
    'pp_arrinit5.c', 294;
    'pp_arrinit6.c', 147;
    'pp_voidparam.c',  7;
    'pp_arrparam.c',   6;
    'pp_arrparam2.c', 98;
    'pp_nonconst.c',   6;
    'pp_nonconst2.c', 42;
    'pp_nonconst3.c', -5;
    'pp_sizeof.c',     4;
    'pp_sizeof2.c',    5;
    'pp_mdim.c',      57;
    'pp_mdim2.c',     93;
    'pp_mdim3.c',     56;
    'pp_mdim4.c',      6;
    'pp_mdim5.c',     82;
    'pp_mdim6.c',      3;
    'pp_mdim7.c',     23;
    'pp_nestedinit.c',  61;
    'pp_nestedinit2.c', 230;
    'pp_nestedinit3.c',  81;
    'pp_globinit.c',     5;
    'pp_globinit2.c',   42;
    'pp_badglobinit.c',  5;
    'pp_sizeofrow.c',   33;
    'pp_ptrrow.c',      22;
    'pp_divmod.c',      89;
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

% printf with length modifiers (%ls, %ld) — stdout check
try
    out = evalc('rc = xc(''tests/programs/pp_prtflen.c'')');
    [npass nfail] = addcheck(npass, nfail, rc == 0 && ...
        strcmp(out, ['hi 42' char(10) 'exit(0)']), ...
        'pp_prtflen.c %ls/%ld normalization');
catch e
    [npass nfail] = addcheck(npass, nfail, false, ...
        sprintf('pp_prtflen.c: %s', e.message));
end

% %n writes the running count; %p prints a hex pointer — stdout checks
try
    out = evalc('rc = xc(''tests/programs/pp_npercent.c'')');
    [npass nfail] = addcheck(npass, nfail, rc == 3 && ...
        strcmp(out, ['abc' 'exit(3)']), 'pp_npercent.c %%n running count');
catch e
    [npass nfail] = addcheck(npass, nfail, false, ...
        sprintf('pp_npercent.c: %s', e.message));
end
try
    out = evalc('rc = xc(''tests/programs/pp_pptr.c'')');
    [npass nfail] = addcheck(npass, nfail, rc == 0 && ...
        ~isempty(strfind(out, 'ptr=0x')), 'pp_pptr.c %%p hex pointer');
catch e
    [npass nfail] = addcheck(npass, nfail, false, ...
        sprintf('pp_pptr.c: %s', e.message));
end

% dynamic width/precision (%*d, %*s, %-*d, %.Ns) — stdout check
try
    out = evalc('rc = xc(''tests/programs/pp_dynwidth.c'')');
    [npass nfail] = addcheck(npass, nfail, rc == 0 && ...
        strcmp(out, ['[   42][   hi][he][7    ]' char(10) 'exit(0)']), ...
        'pp_dynwidth.c %%* width/precision');
catch e
    [npass nfail] = addcheck(npass, nfail, false, ...
        sprintf('pp_dynwidth.c: %s', e.message));
end

% & on a non-lvalue errors (strict address-of)
try
    out = evalc('rc = xc(''tests/programs/pp_badaddrof.c'')');
    [npass nfail] = addcheck(npass, nfail, false, ...
        'pp_badaddrof.c should error');
catch e
    [npass nfail] = addcheck(npass, nfail, ...
        ~isempty(strfind(e.message, 'bad address of')), ...
        'pp_badaddrof.c & on non-lvalue errors');
end

% array initializer errors are clear (too many / bad form)
try
    out = evalc('rc = xc(''tests/programs/pp_badarrinit.c'')');
    [npass nfail] = addcheck(npass, nfail, false, ...
        'pp_badarrinit.c should error');
catch e
    [npass nfail] = addcheck(npass, nfail, ...
        ~isempty(strfind(e.message, 'too many array initializer')), ...
        'pp_badarrinit.c too-many-initializers error');
end

% char-array string initializer too long errors
try
    out = evalc('rc = xc(''tests/programs/pp_badarrinit2.c'')');
    [npass nfail] = addcheck(npass, nfail, false, ...
        'pp_badarrinit2.c should error');
catch e
    [npass nfail] = addcheck(npass, nfail, ...
        ~isempty(strfind(e.message, 'string initializer too long')), ...
        'pp_badarrinit2.c string-too-long error');
end

% --- group 10: assembly track (cc_int, gcc-gated) ---
% Norasandler parts 2-3 (unary + bitwise binary operators). Only runs when
% gcc is available; the check compiles the generated .s, runs the .exe,
% and compares the 8-bit exit status. NOTE: the runtime's system() maps
% the process exit code to its low byte but reports an all-ones 32-bit code
% (return -1) as -1 — a confirmed-successful run with a negative status
% means the program returned -1, i.e. 255.
gcc = 'C:\msys64\ucrt64\bin\gcc.exe';
if exist(gcc, 'file') ~= 2
    gcc = 'gcc';
end
[gcc_ok, ~] = system([gcc, ' --version']);
if gcc_ok ~= 0
    fprintf('SKIP  cc_int group (gcc not found)\n');
else
    cctests = {
        'return_2.c',     2;
        'cc2_neg.c',    214;
        'cc2_not.c',    213;
        'cc2_lnat.c',     0;
        'cc2_lnat0.c',    1;
        'cc2_pos.c',     42;
        'cc2_nested.c',   1;
        'cc2_not0.c',   255;
        'cc2_neg0.c',     0;
        'cc2_lnatneg.c',  0;
        'cc2_negnot.c',   6;
        'cc3_or.c',      47;
        'cc3_and.c',      8;
        'cc3_xor.c',     39;
        'cc3_shl.c',     16;
        'cc3_shr.c',      8;
        'cc3_shrneg.c', 252;
        'cc3_prec1.c',    7;
        'cc3_prec2.c',    7;
        'cc3_prec3.c',  240;
        'cc3_prec4.c',    1;
        'cc3_shrall.c', 255;
        'cc3_mixed.c',   23;
        'cc4_or00.c',     0;
        'cc4_or01.c',     1;
        'cc4_or10.c',     1;
        'cc4_or11.c',     1;
        'cc4_and00.c',    0;
        'cc4_and01.c',    0;
        'cc4_and10.c',    0;
        'cc4_and11.c',    1;
        'cc4_orval.c',    1;
        'cc4_andval.c',   1;
        'cc4_prec1.c',    1;
        'cc4_prec2.c',    0;
        'cc4_prec3.c',    1;
        'cc4_mix.c',      1;
        'cc4_notmix.c',   1;
        'cc4_assoc.c',    1;
        'cc4_assoc2.c',   0;
        'cc5_lt.c',       1;
        'cc5_lt0.c',      0;
        'cc5_gt.c',       1;
        'cc5_gt0.c',      0;
        'cc5_le.c',       1;
        'cc5_le0.c',      0;
        'cc5_ge.c',       1;
        'cc5_ge0.c',      0;
        'cc5_eq.c',       1;
        'cc5_eq0.c',      0;
        'cc5_ne.c',       1;
        'cc5_ne0.c',      0;
        'cc5_signed.c',   1;
        'cc5_signed0.c',  0;
        'cc5_prec1.c',    1;
        'cc5_prec2.c',    1;
        'cc5_prec3.c',    1;
        'cc5_prec4.c',    1;
        'cc5_prec5.c',    1;
        'cc5_negcmp.c',   1;
        'cc5_chain.c',    1;
        'cc5_chain2.c',   0;
        'cc5_mix.c',      1;
        'cc6_add.c',      8;
        'cc6_sub.c',      2;
        'cc6_mul.c',     15;
        'cc6_div.c',      3;
        'cc6_mod.c',      1;
        'cc6_divneg.c', 253;
        'cc6_modneg.c', 255;
        'cc6_modneg2.c',  1;
        'cc6_prec1.c',   14;
        'cc6_paren.c',   20;
        'cc6_negparen.c', 251;
        'cc6_prec2.c',    5;
        'cc6_assoc1.c',   1;
        'cc6_prec3.c',    1;
        'cc6_prec4.c',    1;
        'cc6_prec5.c',    8;
        'cc6_assoc2.c',  50;
        'cc6_assoc3.c',  10;
        'cc6_divneg2.c', 253;
        'cc6_mix1.c',     7;
        'cc6_assoc4.c',  24;
        'cc6_paren2.c',  21;
        'cc6_negparen2.c', 236;
        'cc6_overflow.c', 44;
        'cc6_overflow2.c', 128;
        'cc7_basic.c',     5;
        'cc7_two.c',       7;
        'cc7_init.c',      5;
        'cc7_initref.c',   7;
        'cc7_rmw.c',       6;
        'cc7_chain.c',    10;
        'cc7_arith.c',    11;
        'cc7_div.c',       3;
        'cc7_cmp.c',       1;
        'cc7_late.c',     11;
        'cc7_sub.c',     100;
        'cc7_three.c',     7;
        'cc7_neg.c',     251;
        'cc7_mod.c',       1;
        'cc7_assignval.c', 4;
        'cc7_shl.c',       8;
        'cc7_stmt.c',      3;
        'cc7_logic.c',     1;
        'cc7_negdiv.c',  254;
        'cc7_copy.c',     42;
        'cc8_if.c',        5;
        'cc8_if0.c',       0;
        'cc8_else.c',      5;
        'cc8_else0.c',     6;
        'cc8_ifnobrace.c', 7;
        'cc8_elsenobrace.c', 5;
        'cc8_while.c',     5;
        'cc8_while2.c',    0;
        'cc8_whileif.c',  30;
        'cc8_nested.c',    9;
        'cc8_elif.c',      3;
        'cc8_retif.c',    42;
        'cc8_retwhile.c', 30;
        'cc8_whilcmp.c',  10;
        'cc8_while0.c',    7;
        'cc8_count.c',     9;
        'cc8_condassign.c', 4;
        'cc8_nestedif.c',  9;
        'cc8_double.c',    7;
        'cc8_sum.c',      15;
    };
    for k = 1:size(cctests, 1)
        try
            cc_int(['tests/programs/' cctests{k,1}], 'tmp_cc.s');
            [st_gcc, ~] = system([gcc, ' tmp_cc.s -o tmp_cc.exe']);
            if st_gcc == 0
                [st_run, ~] = system('tmp_cc.exe');
                if st_run < 0
                    st_run = st_run + 256;   % return -1 (0xFFFFFFFF)
                end
                got = st_run;
            else
                got = -999;
            end
            [npass nfail] = addcheck(npass, nfail, got == cctests{k,2}, ...
                sprintf('cc_int %s -> exit %d', cctests{k,1}, cctests{k,2}));
        catch e
            [npass nfail] = addcheck(npass, nfail, false, ...
                sprintf('cc_int %s: %s', cctests{k,1}, e.message));
        end
    end
    delete('tmp_cc.s');
    delete('tmp_cc.exe');
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
