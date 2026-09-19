% run_tests — xc.m test harness.
%
% Run from the project root:
%   matlab.bat tests/run_tests.m
% or (batch mode — the clone does not resolve a script's local functions when
% the script is run by name after addpath, so invoke the file with run()):
%   matlab.bat -batch "run('tests/run_tests.m');"
%
% Exits non-zero if any test fails.

addpath('src');
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
    'pp_globalcexpr.c',  3;
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

% nested-brace initializers enforce the same too-many guard as flat ones
try
    out = evalc('rc = xc(''tests/programs/pp_badnestedinit.c'')');
    [npass nfail] = addcheck(npass, nfail, false, ...
        'pp_badnestedinit.c should error');
catch e
    [npass nfail] = addcheck(npass, nfail, ...
        ~isempty(strfind(e.message, 'too many array initializer')), ...
        'pp_badnestedinit.c nested-brace too-many error');
end

% & on a bare literal errors (the literal's VALUE used to collide with
% the LI/LC opcode numbers, silently accepting &(9) and &(10))
try
    out = evalc('rc = xc(''tests/programs/pp_badaddrof2.c'')');
    [npass nfail] = addcheck(npass, nfail, false, ...
        'pp_badaddrof2.c should error');
catch e
    [npass nfail] = addcheck(npass, nfail, ...
        ~isempty(strfind(e.message, 'bad address of')), ...
        'pp_badaddrof2.c & on literal errors');
end

% a non-lvalue on the left of '=' errors (same collision let (9) = 5 pass)
try
    out = evalc('rc = xc(''tests/programs/pp_badassign.c'')');
    [npass nfail] = addcheck(npass, nfail, false, ...
        'pp_badassign.c should error');
catch e
    [npass nfail] = addcheck(npass, nfail, ...
        ~isempty(strfind(e.message, 'bad lvalue in assignment')), ...
        'pp_badassign.c non-lvalue assignment errors');
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
% the corpus tables live OUTSIDE the gate: the gcc-free groups (x86sim,
% instruction-count regression, ppunit fixtures, error checks) need them
% even when gcc is absent
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
        'cc9_call.c',     42;
        'cc9_args.c',      7;
        'cc9_three.c',     6;
        'cc9_fact.c',    120;
        'cc9_fib.c',      55;
        'cc9_multicall.c', 81;
        'cc9_nested.c',   10;
        'cc9_callee.c',   15;
        'cc9_mutual.c',   10;
        'cc9_exprargs.c', 25;
        'cc9_arith.c',    63;
        'cc9_assign.c',    7;
        'cc9_deep.c',    100;
        'cc9_locals.c',   13;
        'cc9_loop.c',     30;
        'cc9_chain.c',     8;
        'cc10_charloc.c',   65;
        'cc10_charinit.c',  65;
        'cc10_charlit.c',   65;
        'cc10_chartrunc.c', 44;
        'cc10_charparam.c', 65;
        'cc10_charparamtrunc.c', 44;
        'cc10_charcmp.c',    1;
        'cc10_charret.c',  121;
        'cc10_global.c',    5;
        'cc10_globalinit.c', 7;
        'cc10_globalchar.c', 65;
        'cc10_globalrw.c', 101;
        'cc10_globalfn.c',   7;
        'cc10_mix.c',      15;
        'cc10_cadd.c',      8;
        'cc10_csub.c',      2;
        'cc10_cmul.c',     15;
        'cc10_cdiv.c',      3;
        'cc10_cmod.c',      1;
        'cc10_cshl.c',     16;
        'cc10_cshr.c',    252;
        'cc10_cand.c',      8;
        'cc10_cor.c',      47;
        'cc10_cxor.c',     39;
        'cc10_cexpr.c',    11;
        'cc10_cchar.c',   130;
        'cc10_cglobal.c',  20;
        'cc10_cparam.c',   15;
        'cc11_arr.c',      65;   % 321 mod 256
        'cc11_arrchar.c', 209;
        'cc11_arrglobal.c', 18;
        'cc11_arrloop.c',  30;
        'cc11_ptr.c',       5;
        'cc11_ptr2.c',      9;
        'cc11_ptr3.c',      6;
        'cc11_ptrarith.c', 230;
        'cc11_ptrsub.c',    3;
        'cc11_chptr.c',   104;
        'cc11_ptrparam.c',  7;
        'cc11_pp.c',        5;
        'cc11_preinc.c',    6;
        'cc11_postinc.c',   6;
        'cc11_incval.c',   56;
        'cc11_preval.c',   66;
        'cc11_incptr.c',    8;
        'cc11_dec.c',       4;
        'cc11_tern.c',    100;
        'cc11_tern2.c',     1;
        'cc11_tern3.c',     3;
        'cc11_for.c',      10;
        'cc11_do.c',        5;
        'cc11_break.c',     6;
        'cc11_cont.c',      8;
        'cc11_forstp.c',    6;
        'cc11_comment.c',   5;
        'cc11_swap.c',     73;
        'cc11_strlen.c',    5;
        'cc11_strlit.c',   99;
        'cc11_strptr.c',    5;
        'cc12_basic.c',    34;
        'cc12_arrow.c',    56;
        'cc12_char.c',     72;
        'cc12_fn.c',       30;
        'cc12_arr.c',      65;   % 321 mod 256
        'cc12_nested.c',   56;
        'cc12_global.c',   42;
        'cc12_arith.c',     7;
        'cc12_pplus.c',     9;
        'cc12_idx.c',       8;
        'cc12_garray.c',    5;
        'cc12_deref.c',     8;
        'cc13_switch.c',   30;
        'cc13_switch2.c',  99;
        'cc13_break.c',     7;
        'cc13_fall.c',    103;
        'cc13_si1.c',      8;
        'cc13_si2.c',      1;
        'cc13_si3.c',      8;
        'cc13_si4.c',     16;
        'cc13_si5.c',      1;
        'cc13_init.c',    65;   % 321 mod 256
        'cc13_ginit.c',   65;   % 321 mod 256
        'cc13_sinit.c',   38;   % 294 mod 256
        'cc13_typedef.c',  5;
        'cc13_enum.c',    21;
        'cc13_enum2.c',  255;
        'cc13_mdim.c',    57;
        'cc13_mdim2.c',    6;
        'cc13_mdim3.c',    7;
        'cc14_nested.c',   6;
        'cc14_nested2.c', 23;
        'cc14_fptr.c',     7;
        'cc14_fptr2.c',   42;
        'cc14_fptr3.c',  155;
        'cc14_goto.c',     1;
        'cc14_goto2.c',    3;
        'cc14_goto3.c',    5;
        'cc14_bv.c',       7;
        'cc14_bv2.c',     42;
        'cc14_bv3.c',     38;
        'cc14_bv4.c',      9;
        'cc15_cast.c',    65;
        'cc15_cast2.c',   44;
        'cc15_comma.c',    3;
        'cc15_comma2.c',   6;
        'cc15_fptrcall.c', 15;
        'cc15_gfptr.c',    5;
        'cc15_gsinit.c',  56;
        'cc15_gsinit2.c', 89;   % 345 mod 256
        'cc15_gsinit3.c', 72;
        'cc15_gsinit4.c',  9;
        'cc15_nestedstruct.c', 89;   % 345 mod 256
        'cc15_shortcircuit.c', 105;
        'cc15_void.c',    11;
        'cc15_void2.c',    5;
        'cc15_assignval.c',  5;
        'cc15_memberaddr.c', 9;
        'cc15_memberarrow.c', 7;
        'cc15_moddiv.c',   3;
        'cc15_sizeoftype.c', 81;   % 41 mod 256
        'cc15_ternary.c',  4;
        'cc16_cfptr.c',   65;
        'cc16_compoundstruct.c',  6;
        'cc16_localenum.c',  2;
        'cc16_localenum2.c', 6;
        'cc16_localstruct.c', 34;
        'cc16_localstruct2.c', 8;
        'cc16_sretfptr.c',  7;
        'cc16_sretfptr2.c', 48;
        'cc16_sretfptr3.c',  9;
        'cc16_sretfptr4.c',  6;
        'cc16_sretfptr5.c', 31;
        'cc16_strarray.c', 105;
        'cc16_strarray2.c', 117;
        'cc16_strarray3.c', 241;
        'cc17_shim.c',   42;
        'cc17_fileio.c',  0;
        'cc18_fptrptr.c', 6;
        'cc18_comp.c',   91;   % 347 mod 256
        'cc18_comp2.c',  98;
        'cc18_unsigned.c', 6;
        'cc18_unsigned2.c', 111;
        'stress.c',       91;   % 5467 mod 256 — needs the fixed clone
        'stress2.c',     132;   % 988156804 mod 256
        'cc18_strbslash.c', 92;   % backslash escapes survive to .string
        'cc18_ushr.c',      0;   % unsigned >>= is a logical shift
        'cc18_ucmp.c',      1;   % unsigned compare >= 2^32 (64-bit borrow)
        'cc18_printfX.c',   0;   % %X uppercase (stdout checked in the sim group)
        'cc18_printf05.c',  0;   % %05d sign placement (stdout checked in the sim group)
        'dreg_denselit.c',  42;  % Bug A: dense-double literal vs 1/10 (sim_num64 + v1.3.47)
        'dreg_globallong.c', 42;  % Bug B: .quad numeric globals store their full width
        'cc19_hex.c', 76;         % hexadecimal integer literals
        'cc20_litforms.c', 104;   % decimal / hex / octal literals (shared dialect)
        'cc20_litwide.c', 7;      % full-width hex + octal (compiler track only)
        'cc21_width.c', 173;      % local short/long, truncation, sizeof (compiler track only)
        'cc22_escapes.c', 27;     % char/string escape sequences
        'cc23_suffix.c', 72;      % integer constant suffixes (u/U/l/L)
    };
    % cross-track parity: corpus programs the interpreter (xc) and the
    % compiler (cc_int) both support and agree on (mod 256 exit codes).
    % Divergences are the known dialect gaps (structs, switch, typedef,
    % for/do/break/continue, +=, &&/|| value semantics, declaration order).
    pshared = {
        'stress.c',
        'stress2.c',
        'cc10_charcmp.c', 'cc10_charinit.c', 'cc10_charlit.c', 'cc10_charloc.c', 'cc10_charparam.c', 'cc10_charparamtrunc.c',
        'cc10_chartrunc.c', 'cc10_global.c', 'cc10_globalchar.c', 'cc10_globalfn.c', 'cc10_globalinit.c', 'cc10_globalrw.c',
        'cc10_mix.c', 'cc11_arr.c', 'cc11_arrchar.c', 'cc11_arrglobal.c', 'cc11_arrloop.c', 'cc11_chptr.c',
        'cc11_comment.c', 'cc11_dec.c', 'cc11_incptr.c', 'cc11_incval.c', 'cc11_postinc.c', 'cc11_pp.c',
        'cc11_preinc.c', 'cc11_preval.c', 'cc11_ptr.c', 'cc11_ptr2.c', 'cc11_ptr3.c', 'cc11_ptrarith.c',
        'cc11_ptrparam.c', 'cc11_ptrsub.c', 'cc11_strlen.c', 'cc11_strlit.c', 'cc11_swap.c', 'cc11_tern.c',
        'cc11_tern2.c', 'cc11_tern3.c', 'cc13_enum.c', 'cc13_enum2.c', 'cc13_ginit.c', 'cc13_init.c',
        'cc19_hex.c',
        'cc20_litforms.c',
        'cc22_escapes.c',
        'cc23_suffix.c',
        'cc13_mdim.c', 'cc13_mdim2.c', 'cc13_mdim3.c', 'cc13_si1.c', 'cc13_si2.c', 'cc13_si3.c',
        'cc13_si5.c', 'cc13_sinit.c', 'cc2_lnat.c', 'cc2_lnat0.c', 'cc2_lnatneg.c', 'cc2_neg.c',
        'cc2_neg0.c', 'cc2_negnot.c', 'cc2_nested.c', 'cc2_not.c', 'cc2_not0.c', 'cc2_pos.c',
        'cc3_and.c', 'cc3_mixed.c', 'cc3_or.c', 'cc3_prec1.c', 'cc3_prec2.c', 'cc3_prec3.c',
        'cc3_prec4.c', 'cc3_shl.c', 'cc3_shr.c', 'cc3_shrall.c', 'cc3_shrneg.c', 'cc3_xor.c',
        'cc4_and00.c', 'cc4_and01.c', 'cc4_and10.c', 'cc4_and11.c', 'cc4_assoc.c', 'cc4_assoc2.c',
        'cc4_mix.c', 'cc4_notmix.c', 'cc4_or00.c', 'cc4_or01.c', 'cc4_or10.c', 'cc4_or11.c',
        'cc4_prec1.c', 'cc4_prec2.c', 'cc5_chain.c', 'cc5_chain2.c', 'cc5_eq.c', 'cc5_eq0.c',
        'cc5_ge.c', 'cc5_ge0.c', 'cc5_gt.c', 'cc5_gt0.c', 'cc5_le.c', 'cc5_le0.c',
        'cc5_lt.c', 'cc5_lt0.c', 'cc5_mix.c', 'cc5_ne.c', 'cc5_ne0.c', 'cc5_negcmp.c',
        'cc5_prec1.c', 'cc5_prec2.c', 'cc5_prec3.c', 'cc5_prec4.c', 'cc5_prec5.c', 'cc5_signed.c',
        'cc5_signed0.c', 'cc6_add.c', 'cc6_assoc1.c', 'cc6_assoc2.c', 'cc6_assoc3.c', 'cc6_assoc4.c',
        'cc6_div.c', 'cc6_divneg.c', 'cc6_divneg2.c', 'cc6_mix1.c', 'cc6_mod.c', 'cc6_modneg.c',
        'cc6_modneg2.c', 'cc6_mul.c', 'cc6_negparen.c', 'cc6_negparen2.c', 'cc6_overflow.c', 'cc6_overflow2.c',
        'cc6_paren.c', 'cc6_paren2.c', 'cc6_prec1.c', 'cc6_prec2.c', 'cc6_prec3.c', 'cc6_prec4.c',
        'cc6_prec5.c', 'cc6_sub.c', 'cc7_arith.c', 'cc7_assignval.c', 'cc7_basic.c', 'cc7_chain.c',
        'cc7_cmp.c', 'cc7_copy.c', 'cc7_div.c', 'cc7_init.c', 'cc7_initref.c', 'cc7_logic.c',
        'cc7_mod.c', 'cc7_neg.c', 'cc7_negdiv.c', 'cc7_rmw.c', 'cc7_shl.c', 'cc7_stmt.c',
        'cc7_sub.c', 'cc7_three.c', 'cc7_two.c', 'cc8_condassign.c', 'cc8_count.c', 'cc8_double.c',
        'cc8_elif.c', 'cc8_else.c', 'cc8_else0.c', 'cc8_elsenobrace.c', 'cc8_if.c', 'cc8_if0.c',
        'cc8_ifnobrace.c', 'cc8_nested.c', 'cc8_nestedif.c', 'cc8_retif.c', 'cc8_retwhile.c', 'cc8_sum.c',
        'cc8_whilcmp.c', 'cc8_while.c', 'cc8_while0.c', 'cc8_while2.c', 'cc8_whileif.c', 'cc9_args.c',
        'cc9_arith.c', 'cc9_assign.c', 'cc9_call.c', 'cc9_callee.c', 'cc9_chain.c', 'cc9_deep.c',
        'cc9_exprargs.c', 'cc9_fact.c', 'cc9_fib.c', 'cc9_loop.c', 'cc9_multicall.c', 'cc9_nested.c',
        'cc9_three.c',
    };
    % programs whose stdout both tracks must agree on (used by the
    % gcc-gated output parity AND the gcc-free x86sim output parity)
    ostests = {
        'cc22_escapes.c';
        'hello.c';
        'p6_printf.c';
        'p6_printf2.c';
        'p6_file.c';
        'p6_malloc.c';
        'cc17_shim.c';
        'pp_addrof.c';
        'pp_addrof2.c';
        'pp_addrof3.c';
        'pp_array.c';
        'pp_array2.c';
        'pp_array3.c';
        'pp_array4.c';
        'pp_arrinit.c';
        'pp_arrinit2.c';
        'pp_arrinit3.c';
        'pp_arrinit4.c';
        'pp_arrinit5.c';
        'pp_arrinit6.c';
        'pp_arrparam.c';
        'pp_arrparam2.c';
        'pp_badglobinit.c';
        'pp_comments.c';
        'pp_divmod.c';
        'pp_dynwidth.c';
        'pp_fdreuse.c';
        'pp_globinit.c';
        'pp_globinit2.c';
        'pp_init.c';
        'pp_init2.c';
        'pp_mdim.c';
        'pp_mdim2.c';
        'pp_mdim3.c';
        'pp_mdim4.c';
        'pp_mdim5.c';
        'pp_mdim6.c';
        'pp_mdim7.c';
        'pp_mread.c';
        'pp_nestedinit.c';
        'pp_nestedinit2.c';
        'pp_nestedinit3.c';
        'pp_nonconst.c';
        'pp_nonconst2.c';
        'pp_nonconst3.c';
        'pp_npercent.c';
        'pp_prtflen.c';
        'pp_ptrrow.c';
        'pp_s.c';
        'pp_sizeof.c';
        'pp_sizeof2.c';
        'pp_sizeofrow.c';
        'pp_void.c';
        'pp_voidparam.c';
        'stress.c';
        'stress2.c';
    };
    % gcc-dependent groups: the compile-and-run exit-code loop and the two
    % parity groups. Everything after their `end` runs without gcc.
    if gcc_ok ~= 0
        fprintf('SKIP  gcc-dependent groups (gcc not found)\n');
    else
    for k = 1:size(cctests, 1)
        try
            got = -999;
            for attempt = 1:2   % retry: the runtime's system()/gcc flake
                delete('tmp_cc.s');
                delete('tmp_cc.exe');   % no stale exe can leak into this test
                cc_int(['tests/programs/' cctests{k,1}], 'tmp_cc.s');
                [st_gcc, ~] = system([gcc, ' tmp_cc.s -o tmp_cc.exe']);
                if st_gcc == 0 && exist('tmp_cc.exe', 'file') == 2
                    [st_run, ~] = system('.\tmp_cc.exe');
                    if st_run < 0
                        st_run = st_run + 256;   % return -1 (0xFFFFFFFF)
                    end
                    got = st_run;
                    break;
                end
            end
            [npass nfail] = addcheck(npass, nfail, got == cctests{k,2}, ...
                sprintf('cc_int %s -> exit %d', cctests{k,1}, cctests{k,2}));
            % cross-track parity: for the shared subset, the interpreter and
            % the compiler must agree (the OS truncates the exit code to the
            % low byte)
            if ~isempty(pshared) && isin(pshared, cctests{k,1})
                ri = xc(['tests/programs/' cctests{k,1}]);
                [npass nfail] = addcheck(npass, nfail, ...
                    mod(double(ri), 256) == got, ...
                    sprintf('parity %s (interp %d == cc %d)', ...
                        cctests{k,1}, mod(double(ri), 256), got));
            end
        catch e
            [npass nfail] = addcheck(npass, nfail, false, ...
                sprintf('cc_int %s: %s', cctests{k,1}, e.message));
        end
    end
    delete('tmp_cc.s');
    delete('tmp_cc.exe');
    % cross-track output parity: programs that print (via the compiler's
    % runtime shims) must produce the SAME stdout through both tracks (the
    % interpreter's trailing 'exit(N)' trace is stripped first).
    for ok = 1:numel(ostests)
        try
            oo = evalc(sprintf('rcx = xc(''tests/programs/%s'')', ostests{ok}));
            op = strfind(oo, 'exit(');
            if ~isempty(op)
                oo = oo(1:op(end)-1);   % strip the interpreter's exit trace
            end
            delete('tmp_cc.s');
            delete('tmp_cc.exe');
            cc_int(['tests/programs/' ostests{ok}], 'tmp_cc.s');
            st_gcc = -1;
            for attempt = 1:2   % retry: the runtime's system()/gcc flake
                delete('tmp_cc.exe');
                st_gcc = system([gcc, ' tmp_cc.s -o tmp_cc.exe']);
                if st_gcc == 0 && exist('tmp_cc.exe', 'file') == 2
                    break;
                end
            end
            if st_gcc ~= 0
                error('gcc failed');
            end
            st_run = system('.\tmp_cc.exe > tmp_cc_out.txt');
            if st_run < 0
                st_run = st_run + 256;
            end
            fid = fopen('tmp_cc_out.txt', 'r');
            if fid < 0
                error('could not read the compiler output');
            end
            oc = char(fread(fid, inf, 'uint8')');
            fclose(fid);
            delete('tmp_cc_out.txt');
            [npass nfail] = addcheck(npass, nfail, strcmp(oc, oo), ...
                sprintf('output parity %s (xc == cc_int stdout)', ostests{ok}));
        catch e
            [npass nfail] = addcheck(npass, nfail, false, ...
                sprintf('output parity %s: %s', ostests{ok}, e.message));
        end
    end
    end

    % gcc-free track: every compiler corpus program must produce the same
    % exit code through the x86sim interpreter (x86sim.m) as through gcc.
    simok = 0;
    simtot = 0;
    for sk = 1:size(cctests, 1)
        try
            delete('tmp_cc.s');
            cc_int(['tests/programs/' cctests{sk,1}], 'tmp_cc.s');
            got = mod(x86sim('tmp_cc.s'), 256);
            simtot = simtot + 1;
            if got == cctests{sk,2}
                simok = simok + 1;
            else
                [npass nfail] = addcheck(npass, nfail, false, ...
                    sprintf('x86sim %s: sim=%d expect=%d', ...
                        cctests{sk,1}, got, cctests{sk,2}));
            end
        catch e
            [npass nfail] = addcheck(npass, nfail, false, ...
                sprintf('x86sim %s: %s', cctests{sk,1}, e.message));
        end
    end
    [npass nfail] = addcheck(npass, nfail, simok == simtot, ...
        sprintf('x86sim corpus: %d/%d exit codes match gcc', simok, simtot));

    % x86sim printf edge cases (no interpreter counterpart): %X must be
    % uppercase, and %05d of a negative puts zeros between sign and digits.
    try
        delete('tmp_cc.s');
        cc_int('tests/programs/cc18_printfX.c', 'tmp_cc.s');
        pxo = evalc('pxr = x86sim(''tmp_cc.s'')');
        [npass nfail] = addcheck(npass, nfail, strcmp(pxo, 'FF'), ...
            'x86sim %%X uppercase');
    catch e
        [npass nfail] = addcheck(npass, nfail, false, ...
            sprintf('x86sim %%X: %s', e.message));
    end
    try
        delete('tmp_cc.s');
        cc_int('tests/programs/cc18_printf05.c', 'tmp_cc.s');
        p5o = evalc('p5r = x86sim(''tmp_cc.s'')');
        [npass nfail] = addcheck(npass, nfail, strcmp(p5o, '-0007'), ...
            'x86sim %%05d sign placement');
    catch e
        [npass nfail] = addcheck(npass, nfail, false, ...
            sprintf('x86sim %%05d: %s', e.message));
    end
    % local width-type declarations through the simulator only: 'word' is
    % a cc_int extension, so gcc cannot be the oracle and the interpreter
    % has no short/word/long at all (see tests/programs/cc21_wordloc.c)
    try
        delete('tmp_cc.s');
        cc_int('tests/programs/cc21_wordloc.c', 'tmp_cc.s');
        wloc = x86sim('tmp_cc.s');
        [npass nfail] = addcheck(npass, nfail, wloc == 0, ...
            'cc_int local word/short/long declarations (sim only)');
    catch e
        [npass nfail] = addcheck(npass, nfail, false, ...
            sprintf('local width types: %s', e.message));
    end

    % dense-double high-precision print (Bug A): %.17g of a dense literal
    % and of division results must match real gcc. When gcc is present the
    % expectation is gcc's own stdout of the same source, so there is no
    % hand-copied gold to drift (the stored string is the gcc-less fallback).
    try
        delete('tmp_cc.s');
        cc_int('tests/programs/dreg_denseprint.c', 'tmp_cc.s');
        dd = evalc('ddr = x86sim(''tmp_cc.s'')');
        dd(dd == char(13)) = [];
        gold = sprintf('a=0.10000000000000001\nc=3.1415926535897931\nd=0.33333333333333331\n');
        if gcc_ok == 0
            delete('tmp_gccd.exe');
            if system([gcc, ' tests/programs/dreg_denseprint.c -o tmp_gccd.exe']) == 0 ...
                    && exist('tmp_gccd.exe', 'file') == 2
                system('.\tmp_gccd.exe > tmp_gccd_out.txt');
                fid = fopen('tmp_gccd_out.txt', 'r');
                if fid > 0
                    gold = char(fread(fid, inf, 'uint8')');
                    fclose(fid);
                    gold(gold == char(13)) = [];
                end
                delete('tmp_gccd_out.txt');
            end
            delete('tmp_gccd.exe');
        end
        [npass nfail] = addcheck(npass, nfail, strcmp(dd, gold), ...
            'x86sim dense-double %.17g print matches gcc');
    catch e
        [npass nfail] = addcheck(npass, nfail, false, ...
            sprintf('x86sim dense-print: %s', e.message));
    end

    % x86sim stdout parity: the same printing programs must produce the same
    % stdout through the gcc-free simulator as through the interpreter.
    so2 = 0;
    for s2k = 1:numel(ostests)
        try
            delete('tmp_cc.s');
            cc_int(['tests/programs/' ostests{s2k}], 'tmp_cc.s');
            so2o = evalc('s2r = x86sim(''tmp_cc.s'')');
            so2x = evalc(sprintf('s2x = xc(''tests/programs/%s'')', ostests{s2k}));
            s2p = strfind(so2x, 'exit(');
            if ~isempty(s2p)
                so2x = so2x(1:s2p(end)-1);
            end
            so2 = so2 + 1;
            if strcmp(so2o, so2x)
                [npass nfail] = addcheck(npass, nfail, true, ...
                    sprintf('x86sim output parity %s', ostests{s2k}));
            else
                [npass nfail] = addcheck(npass, nfail, false, ...
                    sprintf('x86sim output parity %s', ostests{s2k}));
            end
        catch e
            [npass nfail] = addcheck(npass, nfail, false, ...
                sprintf('x86sim output parity %s: %s', ostests{s2k}, e.message));
        end
    end

    % instruction-count regression: the corpus's total emitted
    % instructions must stay at or below the recorded ceiling, so a future
    % change cannot silently bloat the generated code. History: 8697 ->
    % 8271 -> 7835 -> 7686 -> 6184 per optimization phase, then 7387
    % (stress.c), 10898 (stress2.c), 10715 (empty-frame no-op fold), 10822
    % (the 2026-08-18 fix-round programs). The 2026-09-06 Bug A/B
    % regression programs (dreg_denselit.c, dreg_globallong.c) then added
    % 102 instructions on this host without the ceiling being raised, and
    % newer clones fold ~28 more than the v1.3.25 measurement that set
    % 10822, so the measured total is 10896. Re-baselined; the value is
    % host-dependent (v1.3.47 reports one more), and it is a clone-lineage
    % baseline, not a real-MATLAB number. cc19_hex.c (hex literals) added
    % 42, so the total is 10938. cc20_litforms.c (81) and cc20_litwide.c
    % (28) then added 109 for the alternative literal bases (octal, and
    % full-width hex/octal). cc21_width.c (101) added the narrow-width
    % declarations/casts/sizeof, so the total is 11148. cc22_escapes.c
    % (93) added the escape sequences, and cc23_suffix.c (71) the integer
    % suffixes, so the total is 11312. See
    % docs/2026-09-07-x86sim-peephole-divergences.md.
    ic_total = 0;
    ic_hello = 0;
    for ick = 1:size(cctests, 1)
        try
            delete('tmp_cc.s');
            cc_int(['tests/programs/' cctests{ick,1}], 'tmp_cc.s');
            ic_total = ic_total + count_instr('tmp_cc.s');
        catch e
            [npass nfail] = addcheck(npass, nfail, false, ...
                sprintf('instr count %s: %s', cctests{ick,1}, e.message));
        end
    end
    try
        delete('tmp_cc.s');
        cc_int('tests/programs/hello.c', 'tmp_cc.s');
        ic_hello = count_instr('tmp_cc.s');
    catch e
        [npass nfail] = addcheck(npass, nfail, false, ...
            sprintf('instr count hello.c: %s', e.message));
    end
    [npass nfail] = addcheck(npass, nfail, ic_total <= 11312, ...
        sprintf('instr regression: corpus %d <= 11312', ic_total));
    [npass nfail] = addcheck(npass, nfail, ic_hello <= 72, ...
        sprintf('instr regression: hello.c %d <= 72', ic_hello));

    % peephole pass unit fixtures — one synthetic input per fold rule,
    % asserting the rewrite fires (and its forbidden line disappears).
    % Keeps every rule in peephole_pass.m individually regression-tested.
    [npass nfail] = ppunit(npass, nfail, ...
        {'\tpushq\t%rbp', '\tjmp\t.Lret1', '.Lret1:', '\tret'}, ...
        {'\tret'}, {'\tjmp\t.Lret1'}, 'ppunit jmp-to-next');
    [npass nfail] = ppunit(npass, nfail, ...
        {'\tjmp\t.Lret1', '\tmovq\t$1, %rax', '.Lskip:', '\tret'}, ...
        {'\tret'}, {'\tmovq\t$1, %rax'}, 'ppunit dead-after-jmp');
    [npass nfail] = ppunit(npass, nfail, ...
        {'\tmovq\t$2, %rax', '\timulq\t$8, %rax', '\tmovq\t%rax, %rbx'}, ...
        {'\tmovq\t$16, %rax'}, {'\timulq'}, 'ppunit imm-fold');
    [npass nfail] = ppunit(npass, nfail, ...
        {'\tje\t.Llo4', '\tjmp\t.Llo2', '.Llo4:', '\tmovq\t%rax, %rbx'}, ...
        {'\tjne\t.Llo2'}, {'\tjmp\t.Llo2'}, 'ppunit jcc-collapse');
    [npass nfail] = ppunit(npass, nfail, ...
        {'\tleaq\t-8(%rbp), %rax', '\tmovq\t(%rax), %rax', ...
         '\tmovq\t%rax, %rbx'}, ...
        {'\tmovq\t-8(%rbp), %rax'}, {'\tleaq'}, 'ppunit load-fold');
    [npass nfail] = ppunit(npass, nfail, ...
        {'\tmovq\t$42, %rax', '\tmovq\t%rax, -8(%rbp)'}, ...
        {'\tmovq\t$42, -8(%rbp)'}, {'\tmovq\t%rax, -8(%rbp)'}, ...
        'ppunit imm-store');
    [npass nfail] = ppunit(npass, nfail, ...
        {'\tleaq\t-16(%rbp), %rax', '\taddq\t$8, %rax', ...
         '\tmovq\t%rax, %rbx'}, ...
        {'\tleaq\t-8(%rbp), %rax'}, {}, 'ppunit offset-fold');
    [npass nfail] = ppunit(npass, nfail, ...
        {'\tcmpq\t%rbx, %rax', '\tsetl\t%al', '\tmovzbl\t%al, %eax', ...
         '\tcmpq\t$0, %rax', '\tje\t.Llo2'}, ...
        {'\tjge\t.Llo2'}, {'\tsetl'}, 'ppunit setcc-fold');
    [npass nfail] = ppunit(npass, nfail, ...
        {'\tpushq\t%rax', '\tmovq\t$5, %rax', '\tmovq\t%rax, %rbx', ...
         '\tpopq\t%rax', '\taddq\t%rbx, %rax'}, ...
        {'\tmovq\t$5, %rbx'}, {'\tpushq\t%rax'}, 'ppunit juggle-fold');
    [npass nfail] = ppunit(npass, nfail, ...
        {'\tpushq\t%rax', '\tmovq\t$7, %rax', '\tpopq\t%rbx', ...
         '\tmovq\t%rax, (%rbx)'}, ...
        {'\tmovq\t%rax, %r8'}, {'\tpopq\t%rbx'}, 'ppunit store-spill');
    [npass nfail] = ppunit(npass, nfail, ...
        {'	pushq	%rbp', '	movq	%rsp, %rbp', '	subq	$0, %rsp', ...
         '	movq	%rbp, %rsp', '	popq	%rbp', '	ret'}, ...
        {'	movq	%rbp, %rsp'}, {'	subq	$0, %rsp'}, 'ppunit empty-frame');
    % the nested-assignment guard: only the inner spill may use r8
    [npass nfail] = ppunit(npass, nfail, ...
        {'\tleaq\t-16(%rbp), %rax', '\tpushq\t%rax', ...
         '\tleaq\t-8(%rbp), %rax', '\tpushq\t%rax', ...
         '\tmovq\t$10, %rax', '\tpopq\t%rbx', '\tmovq\t%rax, (%rbx)', ...
         '\tpopq\t%rbx', '\tmovq\t%rax, (%rbx)'}, ...
        {'\tpushq\t%rax', '\tmovq\t%rax, %r8'}, {}, ...
        'ppunit nested-spill-guard');
    % rule 9's shift tail: byte-width shift counts land in %ecx (%rcx is
    % not a valid movzbl/movsbl destination), word counts in %rcx
    [npass nfail] = ppunit(npass, nfail, ...
        {'\tpushq\t%rax', '\tmovzbl\t-8(%rbp), %eax', '\tmovq\t%rax, %rcx', ...
         '\tpopq\t%rax', '\tshlq\t%cl, %rax'}, ...
        {'\tmovzbl\t-8(%rbp), %ecx'}, {'\tpushq'}, 'ppunit juggle-shift-byte');
    [npass nfail] = ppunit(npass, nfail, ...
        {'\tpushq\t%rax', '\tmovq\t$4, %rax', '\tmovq\t%rax, %rcx', ...
         '\tpopq\t%rax', '\tshlq\t%cl, %rax'}, ...
        {'\tmovq\t$4, %rcx'}, {'\tpushq'}, 'ppunit juggle-shift-word');
    % the r8 store-spill folds when the rhs contains a non-%rsp addq
    % (the depth counter once treated any addq as a stack pop)
    [npass nfail] = ppunit(npass, nfail, ...
        {'\tpushq\t%rax', '\tmovq\t-8(%rbp), %rax', '\taddq\t$16, %rax', ...
         '\tpopq\t%rbx', '\tmovq\t%rax, (%rbx)'}, ...
        {'\tmovq\t%rax, %r8', '\tmovq\t%rax, (%r8)'}, {'\tpopq\t%rbx'}, ...
        'ppunit store-spill-addq');

    % static globals audit: every function must declare the file-globals
    % it touches. Real MATLAB scopes are isolated, so a missing declaration
    % (read before any local assignment) is a runtime error that the
    % lenient clones hide -- see check_globals.m. The checker is itself
    % self-tested on a synthetic violation so a broken checker cannot
    % pass silently.
    gsrc = {};
    gdir = dir('src');              % the clone's dir() rejects wildcards
    for gj = 1:numel(gdir)
        gnm = gdir(gj).name;
        if numel(gnm) > 2 && strcmp(gnm(end-1:end), '.m')
            gsrc{end+1} = ['src/' gnm];
        end
    end
    for gk = 1:numel(gsrc)
        try
            gb = check_globals(gsrc{gk});
            [npass nfail] = addcheck(npass, nfail, isempty(gb), ...
                sprintf('globals audit %s', gsrc{gk}));
            for gq = 1:numel(gb)
                fprintf('   %s\n', gb{gq});
            end
        catch e
            [npass nfail] = addcheck(npass, nfail, false, ...
                sprintf('globals audit %s: %s', gsrc{gk}, e.message));
        end
    end
    gsf = 'tmp_globals_selftest.m';
    gf = fopen(gsf, 'w');
    fprintf(gf, 'function gs_main()\n');
    fprintf(gf, 'global gshared\n');
    fprintf(gf, 'gshared = 1;\n');
    fprintf(gf, 'gs_helper();\n');
    fprintf(gf, 'end\n');
    fprintf(gf, 'function gs_helper()\n');
    fprintf(gf, 'disp(gshared);\n');
    fprintf(gf, 'end\n');
    fclose(gf);
    try
        gb = check_globals(gsf);
        [npass nfail] = addcheck(npass, nfail, numel(gb) == 1, ...
            'globals audit self-test (synthetic violation caught)');
    catch e
        [npass nfail] = addcheck(npass, nfail, false, ...
            sprintf('globals audit self-test: %s', e.message));
    end
    delete(gsf);

    % function called with the wrong number of arguments errors
    try
        cc_int('tests/programs/cc9_badargs.c', 'tmp_cc.s');
        [npass nfail] = addcheck(npass, nfail, false, ...
            'cc9_badargs.c should error');
    catch e
        [npass nfail] = addcheck(npass, nfail, ...
            ~isempty(strfind(e.message, 'called with 2 args')), ...
            'cc9_badargs.c arg-count error');
    end
    % a FORWARD call with the wrong arg count errors once the parse
    % completes (the at-call check only fires for already-parsed callees)
    try
        cc_int('tests/programs/cc9_badargs2.c', 'tmp_cc.s');
        [npass nfail] = addcheck(npass, nfail, false, ...
            'cc9_badargs2.c should error');
    catch e
        [npass nfail] = addcheck(npass, nfail, ...
            ~isempty(strfind(e.message, 'called with 2 args')), ...
            'cc9_badargs2.c forward arg-count error');
    end


fprintf('run_tests: %d tests, %d passed, %d failed\n', npass + nfail, npass, nfail);
fid = fopen('run_tests.log', 'a');
if fid > 0
    fprintf(fid, 'run_tests: %d tests, %d passed, %d failed\n', ...
        npass + nfail, npass, nfail);
    fclose(fid);
end
if nfail > 0
    error(sprintf('run_tests: %d failures', nfail));
end

% ---------------------------------------------------------------------------
function [npass, nfail] = addcheck(npass, nfail, cond, name)
if cond
    fprintf('PASS  %s\n', name);
    npass = npass + 1;
    tag = 'PASS';
else
    fprintf('FAIL  %s\n', name);
    nfail = nfail + 1;
    tag = 'FAIL';
end
% Incremental log: the engine buffers stdout until process exit, so a
% run killed mid-way (host suspend) loses every PASS/FAIL line. Append
% each check to run_tests.log (fclose flushes) so partial runs leave a
% readable record up to the kill point.
fid = fopen('run_tests.log', 'a');
if fid > 0
    fprintf(fid, '%s  %s\n', tag, name);
    fclose(fid);
end
end

function b = isin(list, s)
% isin — membership in a cell list. (strcmp(cell, str) is broken on the
% clone — returns a scalar 0 — so compare element by element.)
b = 0;
for k = 1:numel(list)
    if strcmp(list{k}, s)
        b = 1;
        return;
    end
end
end

function n = count_instr(fname)
% count_instr — count the instruction lines in a .s file emitted by
% cc_int: tab-led mnemonics (directives start with '.', labels contain
% ':' and are excluded). -1 on an unreadable file.
fid = fopen(fname, 'r');
if fid < 0
    n = -1;
    return;
end
txt = char(fread(fid, inf, 'uint8')');
fclose(fid);
n = 0;
lines = strsplit(txt, char(10));
for k = 1:numel(lines)
    L = strtrim(lines{k});
    if numel(L) >= 2 && L(1) ~= '.' && isempty(strfind(L, ':'))
        n = n + 1;
    end
end
end

function [npass nfail] = ppunit(npass, nfail, inputs, musthave, mustlack, tag)
% ppunit — feed synthetic assembly lines (with '\t' placeholders) through
% peephole_pass and assert the rewrite fired: every musthave line is
% present and every mustlack line is absent in the output.
T = char(9);
out = {};
for k = 1:numel(inputs)
    out{end+1} = strrep(inputs{k}, '\t', T);
end
r = peephole_pass(out);
s = '';
for k = 1:numel(r)
    s = [s, char(r{k}), char(10)];
end
ok = 1;
for k = 1:numel(musthave)
    if isempty(strfind(s, strrep(musthave{k}, '\t', T)))
        ok = 0;
    end
end
for k = 1:numel(mustlack)
    if ~isempty(strfind(s, strrep(mustlack{k}, '\t', T)))
        ok = 0;
    end
end
[npass nfail] = addcheck(npass, nfail, ok, tag);
end
