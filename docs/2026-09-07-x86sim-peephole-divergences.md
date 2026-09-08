# x86sim / peephole divergences from gcc + real MATLAB

Observed 2026-09-07 by running the full `tests/run_tests.m` under two
interpreters (the v1.3.47 MATLAB clone and the matlab_in_rust Rust
engine, D:/tmp/cciso isolated copy). The suite's green oracle is real
MATLAB; both interpreters pass the compiler/cc_int track completely and
fail only a small x86sim/peephole tail. Items below are grouped by where
the divergence sits. `R` = matlab_in_rust engine, `C` = v1.3.47 clone.

## Resolution status 2026-09-08 (in the Writing-a-C repo)

Items A1 and A2 were already fixed and suite-guarded in this repo BEFORE
this doc was written (the doc's residual runs used the isolated
D:/tmp/cciso copy, which predated them): A1 dense `%.17g` print is fixed
by `5c31063` and asserted at `tests/run_tests.m:922` (dreg_denseprint.c,
gold string), A2 `%X` uppercase by the 2026-08-18 fix round (`5645461`)
and asserted at run_tests.m:905; the x86sim no-operand fix landed as
`1fd742b`. A3 below is a genuine x86sim.m bug fixed here with a one-liner.
Item C's state-carrying hypothesis is falsified: peephole_pass.m has no
globals or persistent state (all helpers are pure, argument-passed), so
the observed ppunit order-dependence was engine-side, not this repo's.

## A. x86sim print/execution gaps (R == C; upstream, need real MATLAB)

Both interpreters agree with each other and disagree with gcc/real
MATLAB. Fixes live in `src/x86sim.m` and must be validated under real
MATLAB.

### A1. dense double %.17g print — `dreg_denseprint.c` (Bug A)

run_tests sim group, expect gcc's stdout:
`a=0.10000000000000001\nc=3.1415926535897931\nd=0.33333333333333331`
Fails identically under R and C. Repro:
```
cc_int('tests/programs/dreg_denseprint.c','t.s'); evalc('x86sim(''t.s'')')
```
Suspect: the sim's double print path (%.17g shortests via sim_num64 /
printf-arg transport) still loses an ulp somewhere (engine prints
0.1000000000000000055-family digits).

### A2. %X uppercase — `cc18_printfX.c`

`printf("%X", v)` for a value with hex digits above 9 must print
uppercase (suite expects captured stdout `FF`). FAILed in R's completed
run; not present in C's fail list — needs a clean single-process rerun to
confirm whether this is A-class or order-dependent (see C).

### A3. unsigned shift — `cc18_unsigned.c` — RESOLVED (2026-09-08)

Exit code: gcc = 6, x86sim under R AND C = 7. The .s is byte-identical
under both engines (compiler correct); the sim's shift of an unsigned
32-bit value gives 3 for `5 >> 1` in an isolated program under both
engines. `cc18_unsigned2.c` and `cc18_ushr.c` pass, so only one shift
form (shrq with a register count? division-shaped shift) is off.
Repro: `cc_int('tests/programs/cc18_unsigned.c','t.s')` then x86sim = 7.

Root cause (NOT an upstream x86sim-vs-gcc gap, and not engine-side): the
shrq branch computes `u / 2^c` where `c = mod(sim_opval(a), 64)` and a
register-count operand (`%cl`) reads back as a RAW int64. Real MATLAB
promotes `double / int64` to double (5/2 = 2.5, floor = 2), but both
clones evaluate integer arithmetic with round-half semantics (2.5 -> 3),
i.e. R and C share an int64-class arithmetic divergence from real MATLAB
that the "R == C -> upstream" inference in the doc's reality check missed.
Only odd-valued shifts divide inexactly, which is why cc18_unsigned2 and
cc18_ushr (even operands / constant forms) passed.

Fix (in this repo, `src/x86sim.m` shrq branch): force the count double so
the float path stays double on every runtime:

    c = double(mod(sim_opval(a), 64));

Behavior-neutral on real MATLAB (a double shift count is canonical
there). Verified on both engines: cc18_unsigned sim 7 -> 6 (== gcc),
cc18_unsigned2 111, cc18_ushr 0, cc18_ucmp 1, cc10_cshl/cshr unchanged.
The existing suite guard (cctests table row `'cc18_unsigned.c', 6` plus
the gcc-free x86sim corpus group's sim == gcc-exit assertion) covers it.

## B. Peephole: interpreter-vs-MATLAB fold gap (R and C both under budget)

`instr regression: corpus N <= 10822` — the corpus instruction count is
R = 11575 and C = 10897, both over the real-MATLAB ceiling of 10822. The
peephole_pass.m rules fold less when interpreted than under real MATLAB,
and R folds 678 fewer than C (so R has an additional engine-side gap in
some fold rule — C and R disagree here, unlike section A).

## C. Order/state dependence inside peephole (needs investigation)

`ppunit imm-fold` FAILed in one full R run, PASSed in the next R run, and
PASSes under C — but feeding the imm-fold fixture to peephole_pass
standalone under BOTH engines returns the input unchanged (no fold):
```
addpath('src'); T=char(9);
r = peephole_pass({['movq',T,'$2, %rax'],['imulq',T,'$8, %rax'],['movq',T,'%rax, %rbx']})
% -> unchanged under R and C; real MATLAB folds to movq $16, %rax
```
This suggests cc_int/peephole_pass carry state across calls in a way
that changes later results (a fold rule firing or not depending on prior
compiles in the same process). The full suite's per-run total also drifts
(795 vs 769 checks) in the same direction. Worth auditing globals in
peephole_pass.m (del/foldmap arrays, mnemonic tables) for reset-on-entry.

## Context

- C clone full run: 768 tests, 577 passed, 191 failed (its own broad
  interpreter gaps on the newest cc_int.m grammar, e.g. many
  `cc_int cc10_charret.c: bad expression` rows — unrelated to the tail
  above).
- R engine full run: 769 tests, 761 passed, 8 failed (the 8 = A1, A2,
  A3, output-parity p6_printf2, B corpus, C ppunit, + 1 double-count).
  R == C on every remaining tail item except B's magnitude.
