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
D:/tmp/cciso copy, which predated them): A1 dense `%.17g` print values are
fixed by `5c31063` (the guard's gold string itself needed a
missing-trailing-newline fix later — `b5af653`), A2 `%X` uppercase by the
2026-08-18 fix round (`5645461`)
and asserted at run_tests.m:905; the x86sim no-operand fix landed as
`1fd742b`. A3 below is a genuine x86sim.m bug fixed here with a one-liner.
Item C's state-carrying hypothesis is falsified: peephole_pass.m has no
globals or persistent state (all helpers are pure, argument-passed), so
the observed ppunit order-dependence was engine-side, not this repo's.

Later update 2026-09-19: the clone lineage caught up. v1.3.53 and
v1.3.68 both scored 584/767 (183 fails: 161 cross-track parity + 20
`cc_int ... bad expression` parse gaps + A1 + B); v1.3.72 fixed every one
of the parity and parse-gap rows, scoring 765/767 with only A1 and B
left. A1's last remnant was the guard itself (see the A1 section), fixed
in `b5af653`; item B then turned out to be a stale ceiling rather than a
fold gap (see the B section), and the globals audit added 8 checks, so
the v1.3.72 run is fully green: **775/775**. Host table in Context below.

## A. x86sim print/execution gaps (R == C; upstream, need real MATLAB)

Both interpreters agree with each other and disagree with gcc/real
MATLAB. Fixes live in `src/x86sim.m` and must be validated under real
MATLAB.

### A1. dense double %.17g print — `dreg_denseprint.c` (Bug A) — RESOLVED

The sim's double-print values were fixed by `5c31063` (sim_num64 parse +
printf-arg transport): cc_int + x86sim now prints gcc's exact
`a=0.10000000000000001`, `c=3.1415926535897931`, `d=0.33333333333333331`
on every host (v1.3.72 clone and the Rust engine, verified 2026-09-19).
The check still failed because the guard's gold string omitted the
program's trailing newline (`dreg_denseprint.c` prints three `...\n`
lines, so gcc's stdout ends with `\n`); fixed in `b5af653`. Not a
runtime divergence at all — a broken assertion.

### A2. %X uppercase — `cc18_printfX.c` — no longer failing

`printf("%X", v)` for a value with hex digits above 9 must print
uppercase (suite expects captured stdout `FF`). It FAILed in one R run
(possibly order-dependent, per C) but does not fail under v1.3.53/68/72,
whose completed runs show the `x86sim %X uppercase` check PASSing. The
`5645461` fix (2026-08-18) is the likely resolution; no repro remains.

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

## B. Instruction-count ceiling — RESOLVED (2026-09-19); not a fold gap

`instr regression: corpus 10896 <= 10822` looked like the interpreters
folding less than real MATLAB. It is not. The 10822 ceiling was set on the
v1.3.25 clone (2026-08-18); the 2026-09-06 Bug A/B regression programs
(`dreg_denselit.c`, `dreg_globallong.c`) then added **102** instructions on
this host without the ceiling being raised, and newer clones fold **~28**
more than the v1.3.25 measurement, giving 10896. No cctests rows were
removed in between, so the corpus only grew.

The pass is fully converged, so there are no missed folds to hunt: feeding
cc_int's output back through `peephole_pass` changes the instruction count
for **none** of the 410 compilable corpus programs (measured 2026-09-19;
the pass already iterates to a fixed point). The ceiling is re-baselined to
10896 in the harness, with the corpus growth recorded. It is a
clone-lineage baseline, not a real-MATLAB number (v1.3.47 reports one
more). The Rust engine's 11575 remains an engine-side gap of its own.

## C. Order/state dependence inside peephole — REFUTED

The one-off `ppunit imm-fold` failure was engine-side and is gone. The
standalone repro in the original note was mis-constructed: the imm-fold
fixture passes deterministically in the suite (`ppunit imm-fold`) under
both the clones and the engine, and `peephole_pass.m` has no globals or
persistent state. The 2026-09-19 idempotency check (section B) confirms
the pass reaches a true fixed point, so nothing carries across calls.

## Context

- C clone full run, newer releases (2026-09-19): v1.3.72 = 767 tests,
  766 passed, 1 failed (only B); v1.3.68 and v1.3.53 = 584 passed / 183
  failed; v1.3.47 (the run behind this doc) = 577 passed / 191 failed.
  The whole clone-side tail — the 161 cross-track parity rows and the 20
  `cc_int ... bad expression` parse gaps — is gone as of v1.3.72.
- R engine full run: never completed on the Sep-14 build — batch mode
  reaches 588 checks with 0 failures (through the whole gcc corpus track)
  then the process dies; script mode dies at 47; `xc(stress2.c)` alone
  runs >9 min at a flat ~8 MB RSS. See
  docs/2026-09-06-rust-engine-compat.md (Postscript 2). The earlier
  769/761/8 run was on the 2026-09-07 engine (before those regressions).
- With item B re-baselined (a stale clone-lineage ceiling, not a fold
  gap — see the B section) and the static globals audit added, the
  v1.3.72 run is fully green: **775/775**. The only outstanding host
  problem is the Rust engine's inability to finish the harness.
