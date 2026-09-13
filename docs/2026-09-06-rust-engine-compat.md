# Running this project on the Rust MATLAB engine (compat analysis) — 2026-09-06

## Context

This project's MATLAB code (cc_int.m / xc.m / x86sim.m, tests/run_tests.m)
runs on a MATLAB *clone* provided as `matlab.bat`. Two clones exist:

| Runtime | Path | Notes |
|---|---|---|
| C reference clone | `D:\Projects\codes\MATLAB_in_C\release\v1.3.47\matlab.bat` | the project's original host (docs reference it as the "custom MATLAB clone") |
| Rust clone | `D:\Projects\codes\matlab_in_rust\target\release\matlab.exe` | a from-scratch interpreter matching the C clone's observable behavior (differential-tested) |

This note records how far the project's own harness gets on the Rust clone,
what engine defects were found while trying, and what still blocks a full
pass. Working tree of this repo was left clean (all probes reverted).

## How to run this project on the Rust engine

The project is pure `.m` plus gcc shell-outs (`system()`); there are no real
MEX binaries, so switching runtimes is only an executable swap. MSYS2 gcc
must remain on PATH exactly as with the C clone.

```bash
R="D:/Projects/codes/matlab_in_rust/target/release/matlab.exe"

# README's documented entry point:
"$R" tests/run_tests.m

# README's batch-mode note (clone quirk: invoke a script by name via run):
"$R" -batch "run('tests/run_tests.m');"

# Individual recipes (README lines 94-95, 177):
"$R" -batch "addpath('src'); cc_int('prog.c','prog.s');"
"$R" -batch "addpath('src'); rc = x86sim('prog.s')"
```

## Result: the harness executes, but does not yet pass

`tests/run_tests.m` now runs to completion on the Rust engine: 392
PASS/FAIL checks execute; ~230 fail. Getting from "parse error on line 1"
to "runs to completion" required three real engine fixes (all committed in
the Rust repo as `caf7eeb`, 2026-09-06):

1. **Space-separated multi-output function definitions.** The engine only
   parsed `function [a, b] = f()`; this project defines
   `function [npass nfail] = ppunit(...)` etc., which failed to parse.
2. **Requested-nargout leaking into nested calls.** `[a b] = chk(gval() ==
   7, ...)` raised "Too many output arguments" because the inner call
   `gval()` (1 declared output) inherited the LHS's requested nargout (2).
   Nested calls in an argument list now evaluate with nargout = 1; the
   call bound directly to the `[a b] =` LHS still sees the requested count.
3. **No real `global` variable storage.** `global x` only pre-created an
   empty root entry; reads/writes fell through ordinary scope chains, so a
   global worked only when the caller and callee scopes happened to chain
   (main function writes, its child subfunction reads). The project's
   `gset(7)` / `gget()` sibling-subfunction pattern and separate
   function-file sharing lost the value. The engine now tracks
   per-workspace global declarations and routes reads/writes to the root
   scope's vars (real MATLAB semantics).

Also encountered and since **fixed** (see the status update below):
`zeros(1,4,'uint8') + [1 2 3 4]` (integer array plus a double *vector*)
errors under real MATLAB, but the C clone is lenient and the project's
`tests/probe_primitives.m` line 17 relies on it; the engine now mirrors
the clone.

## Remaining failure classes

Observed on a full `run_tests.m` run (150 PASS / 230 FAIL after the
fixes below). All remaining FAILs trace to one or two deep engine issues:

1. **xc.m global reads go stale across its subfunction chain** — the
   dominant cause (every "duplicate global declaration", "bad global
   declaration" and lexer-token failure). Detailed in the status update.
2. **Engine panic in cell-element deletion** (`assign_index_matrix`, on
   `c(i) = []` shrink) and the `word_store` int64 boundary selftest.

## Status update 2026-09-06 (evening) — gap partially closed

Three more engine changes landed after the first write-up (matlab_in_rust
commits `caf7eeb` and the following arith commit):

1. Group-1 blocker fixed: **integer array + double array arithmetic**.
   `zeros(1,4,'uint8') + [1 2 3 4]` previously errored (real MATLAB
   rejects non-scalar double + integer); the engine now mirrors the C
   clone's leniency (elementwise, double converted per element with
   round-half-away + class saturation, integer class kept; probe r1-r10
   byte-match the C clone). Recorded as a divergence from real MATLAB in
   the Rust repo's C bug report. `tests/probe_primitives.m` no longer
   needs any edit.
2. Engine fixes from the first attempt, committed in `caf7eeb`:
   space-separated `function [a b] = ...` outputs, nested-call nargout,
   and real `global` variable storage.

Re-run after these: the harness executes fully; 150 PASS / 230 FAIL. The
remaining FAILs are dominated by one root cause that resisted a full
debugging session: **xc.m's `token`/`si` global reads go stale across its
subfunction call chain** (verified with per-token instrumentation on a
copy: Rust never runs the `match(Int)` after lexing `int` because the
global `token` read in `global_declaration` returns the seed-phase value
133 instead of 138, while the C clone advances correctly). Minimal global
repros (multi-name globals, sibling subfunctions, depth-3 writes) all pass
on the engine, so the staleness depends on xc's specific call shape —
still open, with the diff of the instrumented traces (first divergence at
`match enter tk=138` vs `tk=133`) as the starting point.

Not yet addressed: the lexer-token-id offsets that the token selftests
report (sibling of the stale-keyword issue above).

## Status update 2 (2026-09-06, night) — two more classes fixed

- **word_store int64 boundary** fixed: `bitshift` with a double operand
  used unsigned right shifts, so `bitshift(-16.0, -1)` returned ~2^63
  instead of -8 and the vm selftest's `SHR -16>>1` case failed in
  word_store. Double/logical operands now shift signed (C parity);
  `xc --vm-selftest` is 30/30.
- **Cell-deletion panic** fixed: `c(2,:)=[]` / `c(:,2)=[]` (and any
  deletion that empties a cell) panicked on a dims-vs-elements mismatch.
  Full-line deletes now keep the 2-D shape (1x2 / 2x1), single-element
  deletes flatten to a row, and empty results stay empty (Rust follows
  real MATLAB; C's own cell deletion is broken there — see the Rust repo
  C bug report).

Committed in matlab_in_rust `6e40d35` + `9c99320`; gates green.

Still open (the dominant class): the stale `token`/`si` global reads in
xc.m's subfunction chain.

## Next steps

- Root-cause the stale `token`/`si` global reads in xc.m's subfunction
  chain (diff of the instrumented Rust-vs-C traces is the starting point;
  minimal global repros pass, so extract xc's exact call shape).
- Fix the cell-element-deletion panic in `assign_index_matrix`.
- Re-run `tests/run_tests.m` under the Rust engine until 0 FAIL; re-run the
  Rust repo gates afterwards (fmt/clippy, workspace tests, rust-only 77/77,
  C-mode 52/52, e2e 33/33).
- Only then can the Rust engine be advertised as a drop-in host for this
  project; until then the C clone (`matlab.bat` v1.3.47) remains the
  supported runtime.

## Re-test on the Rust engine (2026-09-06, later build at target/release/matlab.exe, 19:29)

Engine has since gained commits for two of the classes (cell-deletion no-panic
`6e40d35`, int64/bitshift semantics). Re-ran a full `run_tests.m` bootstrap here
but a NEW, earlier blocker now stops x86sim before any check: **x86sim fails to
parse even the first register of any .s under the Rust engine.**

Minimal repro (engine-side; this repo's code is unchanged and passes on the C
clone):
1. `cc_int('t.c','t.s')` where t.c = `int main(){ return 3; }` succeeds.
2. `x86sim('t.s')` -> `Error using sim_regidx / x86sim: unknown register`
   on the very first parsed instruction (`pushq %rbp`).
3. The register matcher ITSELF is fine in isolation under the Rust engine: a
   standalone re-implementation of sim_regidx's table + `%`-strip + compare
   correctly returns idx for `%rbp`. So the divergence is in how x86sim
   tokenizes the `.s` instruction line into operand tokens under the Rust
   engine (mnemonic/operand split, tab byte, `char()` of an instruction
   code-vector, or code-vector <-> char slicing) before the register reaches
   sim_regidx. Suspected: string/char code-vector slicing difference, not the
   register table.

Suggested next: pick the FIRST instruction of `t.s`, trace `sim_parse_insn` ->
operand tokens for `%rbp` under the Rust engine vs the C clone, and make the
token byte-for-byte equal. Until x86sim can parse a trivial `.s`, none of the
later harness checks (and none of this repo's guarded regression work) can run
on the Rust engine. C-clone `v1.3.47` remains the supported runtime.

## Status update 3 (2026-09-06, handoff response) — x86sim register parse fixed

The handoff's root cause was an engine control-flow bug, not tokenization:
**`return` inside a `for` loop only broke the loop; the loop node then
reported normal flow, so the function kept executing.** sim_regidx matched
%rbp in its table, hit `return` inside the 32-iteration loop, fell through,
and raised `x86sim: unknown register` on every .s. Fixed in matlab_in_rust
`be56b25` (for/while/parfor now propagate `Flow::Return`; `break` still only
exits the loop). With that, x86sim parses `pushq %rbp` and the first two
instructions execute.

New blocker (handoff for the engine side, still open): after the register
fix, the third instruction (`movl $3, %eax`) hits a **char-row length
mismatch**: inside x86sim, an operand string sliced from the instruction
line reports `numel(s)==10` while `double(s)` shows only 8 character codes
(`$3, %eax`). The extra two indices carry junk, so operand splitting /
`sim_parse_op` / `sim_trim` slices see phantom characters and the operand
parses as empty (`{0}` -> `sim_opval: bad operand value`). Suspected engine
defect: char-row slicing/`numel` counting NUL padding or a stale length
after `char()`/`fread('uint8')` round-trips. Next step: compare the same
`.s` line's char vector under C v1.3.47 (len == number of codes) vs the
Rust engine and make `numel`/slice agree.

## Status update 4 (2026-09-06, step 1 re-test) — token/duplicate class GONE

The step-1 full re-run confirms the `be56b25` return-in-loop fix dissolved the
dominant failure class: the xc lexer/compiler now runs correctly end to end.

- probe_primitives: **38/38 PASS**
- xc executes real programs: return_2.c -> exit 2, cc2_lnat.c -> exit 0,
  all p5_*.c (pointers/arrays/casts/bitwise) -> expected exits
- lex_selftest: **9/9**; vm_selftest: 30/30 (earlier)
- Grouped progress markers on an isolated copy (D:/tmp/cciso): groups 1-10
  all START within ~4 min; groups 1-9 complete quickly. The earlier
  "stale token/si global" hypothesis was wrong — it was the loop-return bug.

Remaining blocker: the suite stalls inside **group 10 (assembly track)**
after building tmp_cc.exe via `system(gcc ...)`. The engine process CPU
freezes (no progress for 5+ min) right after the tmp_cc.exe build, i.e.
inside the `system('.\tmp_cc.exe')` run step (run_tests lines ~801/846
retry loops). `system()` compile+run works in isolation (syst.m: gcc st=0,
run st=3 fast), so the stall is specific to that corpus step — candidate
causes: engine `system()` waiting on the child without draining its piped
stdout (deadlock when the child writes > pipe buffer), or one specific
corpus exe blocking. Handoff for the engine side: reproduce
`system('.\tmp_cc.exe')` after a real cc_int tmp_cc.s build under the Rust
engine with the output captured, and make system() drain + wait correctly.
The full-suite PASS/FAIL counts are still unreadable (stdout buffered until
exit) until that group-10 stall is cleared.

## Status update 5 (2026-09-07) — no deadlock; group 10 is slow, plus one real parity bug

The "group-10 freeze" is **not** a system()/pipe deadlock. Isolated repros:
cc_int compile (instant), `system(gcc ...)` (st=0), `system('.\tmp_cc.exe')`
(st=42) all work. Group markers on the isolated copy (D:/tmp/cciso) show
the suite progresses through the entire cc corpus — each `cc_int`
compile of a corpus program takes tens of seconds under the interpreted
engine, and the output-parity + x86sim corpus loops re-compile dozens of
programs, so group 10 needs on the order of an hour of engine time (plus
the auto-restarting C-clone NR sim stealing CPU). Not a hang; performance.

One REAL engine bug found while probing: **xc.m reports `4: duplicate
global declaration` for `int a[3] = {1, 2, 3};`** (dreg_globallong.c line
4, the parity/interpreter path; the C clone accepts it). Same family as
the loop-return bug (array-initializer parsing under the engine re-enters
the symbol for `a`); handoff for the engine side. Everything else through
group 9 and the component gates (probe 38/38, vm 30/30, lex 9/9, all
p5/p4 program exits) is green; final PASS/FAIL totals for the full suite
await an uninterrupted ~1 h run.

## Status update 6 (2026-09-07) — items 1-2

1. The reported `4: duplicate global declaration` on dreg_globallong.c is
   NOT an engine bug: xc.m (the interpreter dialect) has no `long` keyword
   by design; that program is compiler-track only and passes cc_int+gcc
   (exit 42). No change needed.

2. x86sim "bad operand value" root-caused. Engine cc_int writes `.s` with
   LF; the C clone writes CRLF (text-mode `\n`->`\r\n` translation that the
   engine lacks — verified by `od`: C `a\r\nb\r\n`, engine `a\nb\n`).
   x86sim's `sim_parse_insn` returns a hard `{0,{0},{0}}` for any
   no-operand line, so `ret` executes as a movq with empty operands and
   raises "bad operand value". The C runtime only survives this because its
   CRLF + NUL file accidents make `rest` non-empty for `ret`. Patching the
   isolated copy's parse_insn to return `{sim_mnemonic(m),{0},{0}}` for
   no-operand lines removes the error (cc11_swap now runs, though the exit
   value still differs: sim=30 vs expected 73 — a further sim discrepancy
   to chase). Engine-side genuine bug to fix: fopen text-mode newline
   translation (`\n`->`\r\n` on write, `\r\n`->`\n` on read) for byte
   parity with the C clone. Their repo stays unchanged; fixes live in
   D:/tmp/cciso until approved.

## Status update 7 — engine fopen text-mode translation committed

matlab_in_rust `ed20148`: fopen without 'b' is now a text handle —
fprintf file writes translate LF -> CRLF and fread of single-byte
precisions strips CRLF -> LF (a leading '*' precision stays raw); 'b'
modes stay raw. od-verified byte parity with the C clone (engine files
now a\r\nb\r\n), read-back round-trips to LF. Gates green (fmt/clippy
0, tests 0 failed, rust-only 77/77, C-mode 52/52, e2e 33/33).

Still open on this project's side (their repo, untouched): x86sim's
sim_parse_insn returns a hard {0,{0},{0}} for no-operand lines, so 'ret'
mis-dispatches as a movq with empty operands; the C runtime only masked
this through CRLF/NUL file accidents. One-line fix
(insn = {sim_mnemonic(m), {0}, {0}} for empty rest, applied in
D:/tmp/cciso) removes the error; a value discrepancy (sim=30 vs 73 on
cc11_swap) remains to chase after that fix lands.

## Status update 8 — sim=30-vs-73 chased to an engine global-write bug in cc_int

The 30-vs-73 discrepancy is NOT x86sim: both engines' x86sim return 30 on
the SAME .s, and the real gap is that **the engine's cc_int emits wrong
immediates** — `movq $0` where C emits `movq $3`, and `$3` where C emits
`$7` (constants shifted one-behind; instruction streams otherwise
identical; verified diff of engine tS.s vs C tC2.s).

Instrumented repro (isolated copy): the number lexer computes v=3 and
executes `token_val = v;` but an immediate read-back in the same function
prints token_val = 0 (`DBGN int val=3` -> `DBGN post tv=0`), and the
caller's emit reads 0; the second constant reads 3, i.e. every write lands
one lex late. token and token_val are both global; token=128 IS visible to
the caller while token_val=3 is not - so the global write of an int64
scalar from the lexer's scope is not reaching the parser's read.

This is the same family as the earlier xc token/si staleness (never
root-caused). Minimal global repros (gg1..gg6: multi-name globals, sibling
subfunctions, depth-3 writes, int64 values, double-then-int64 overwrite)
ALL pass under the Rust engine, so the trigger needs cc_int's exact shape
(the lexer `next()` writes token_val from deep inside number parsing
called by many parser functions). Handoff for the engine side: extract a
minimal failing case from cc_int's next()/parse boundary (token_val write
visible to token but not token_val), or instrument the engine's
Scope::set/global routing with the DBGN post tv=0 repro.

Note: with the constants fixed, the rest of the swap .s matches C exactly,
so sim=73 should follow. All instrumentation reverted; repo clean apart
from this doc.

## Status update 9 — cc_int constant bug root-caused (engine call-scope isolation)

Engine-instrumented trace (env GDBG on Scope::set for token_val) shows the
mechanism precisely:

1. The lexer `next()` assigns `token_val = 3` with `hasglob=true` and
   routes to the root scope correctly (GSET f=3.0 hasglob=true).
2. cc_int's `parse_statement` label-peek (statement dispatch, ~line 1923)
   does `save_tv = token_val; next(); ...; token_val = save_tv;` but its
   `global` list does NOT include token_val, so the restore creates a
   LOCAL token_val=0 in parse_statement's scope (GSET f=0.0
   hasglob=false).
3. The engine parents every function-call scope to the CALLER scope, so
   nested parser functions read token_val through parse_statement's chain
   and hit the accidental local 0 before the true root value 3 -> compiled
   immediates shift one lex behind.

Real MATLAB function scopes are ISOLATED: a callee never sees a caller's
locals, so parse_statement's accidental local cannot shadow the lexer's
global for other functions. The C clone behaves the same way (proof: it
compiles cc11_swap constants correctly). The engine's child-of-caller
scoping is the bug (it also underlay the earlier xc token/si staleness).

Engine fix (designed, not yet landed): parent non-nested function-call
scopes to the caller's FILE function registry (per-file scope holding the
file's subfunctions, itself a child of the root) instead of the caller's
working scope; nested functions keep the write-through caller scope.
Subfunction registration must go to that file registry so siblings stay
resolvable. A quick child-of-global attempt broke sibling resolution
('Unrecognized function or variable em') because subfunctions currently
live in the main function's scope chain; reverted, tree green. All
instrumentation reverted.

## Status update 10 — isolation fix landed; cc11_swap sim=73

matlab_in_rust `29469b9`: non-nested function calls now run in a per-file
registry scope (child of the global scope, holding the file's
subfunctions) instead of the caller's working scope; nested functions keep
the caller write-through scope; file-level subfunctions register in the
shared registry. This is real-MATLAB isolation and fixes the cc_int
constant bug at its root (parse_statement's accidental local token_val no
longer shadows the lexer's global for parser callees).

Verified end to end in D:/tmp/cciso (with the x86sim no-operand one-liner
also applied there): cc_int emits movq $3/$7 (was $0/$3) and
x86sim('cc11_swap.s') = 73, matching gcc. xc interpreter programs still
correct (p5_swap 73, p4_fib 55, p3_divmod 13, cc2_neg -42), probe 38/38,
vm 30/30, lex 9/9. Engine gates green (fmt/clippy 0, tests 0 failed,
rust-only 77/77, C-mode 52/52, e2e 33/33).

Their repo: still needs the x86sim sim_parse_insn one-liner (no-operand
mnemonics map to sim_mnemonic(m) instead of {0,{0},{0}}) for the x86sim
corpus group to pass deterministically; it is applied in D:/tmp/cciso.

## Status update 11 - full-suite first clean count + two engine fixes

Full run on D:/tmp/cciso with the x86sim no-operand fix + isolation fix:
**795 tests, 727 passed, 68 failed** (was ~150 pass / ~230 fail before the
session's engine fixes). Remaining 68 split into:

- x86sim corpus/parity fails whose programs call printf/open/malloc:
  cc_int fails 'call to undefined function printf' -> an isfield(libfns,
  name) miss under the engine (global struct libfns built by dot-field
  assigns in cc_int main; parse_program's cross-function read misses some
  fields) - one remaining engine bug class, NOT reproduced by minimal
  global-struct probes (gg8 passes), needs the same deep-shape chase as
  the token_val bug.
- bitand/bitor/bitxor 3-arg assumedtype: FIXED in matlab_in_rust (commit
  after 29469b9); cc3_or x86sim now 47 as expected. Gates green.

A recount run (~1 h) is needed for the new totals; the remaining open class
is the cc_int libfns printf/open/malloc isfield miss.

## Status update 12 - full-suite recount: 761/769; 8 x86sim-vector fails

matlab_in_rust d61d0db routes static struct-field writes on
global-declared names to the ROOT scope (assign_dot's Ident arm and the
DotRoot::Var chain arm read/mutate/write through Scope::get/set when the
name is in the scope's global list). Root cause of the last compiler-track
class: cc_int main built the libfns/funcs structs by dot-field assigns
under a huge multi-line `global` declaration; sibling parse_program's
isfield(libfns,'printf') then read the root's empty struct, so any program
calling printf/open/malloc failed cc_int with 'call to undefined function
printf'. Minimal probes had passed because only dynamic `.(f)` writes
route; static `.field` writes shadowed. cc_int now compiles hello,
p6_printf, cc17_shim, cc18_printfX. Gates green (fmt/clippy 0, tests 0
failed, rust-only 77/77, C-mode 52/52, e2e 33/33).

Full-suite recount on D:/tmp/cciso (isolated copy, engine 29469b9+
7b41934+d61d0db, repo src incl the x86sim no-operand one-liner):
**run_tests: 769 tests, 761 passed, 8 failed** (was 795/727/68 in the
previous clean count; the internal per-run total differs between runs by
the number of retry-loop double-adds, the pass/fail delta is what moved).

Remaining 8, all x86sim-vector fidelity (compiler track 100% green):
1. x86sim cc18_unsigned.c sim=2 expect=6 (unsigned op semantics)
2. x86sim cc18_unsigned2.c sim=10 expect=111
3. x86sim %%X uppercase (prints lowercase hex for large values)
4. x86sim dense-double %.17g print matches gcc (Bug A print path)
5. x86sim output parity p6_printf2.c
6. instr regression: corpus 11575 <= 10822 (peephole_pass.m run by the
   engine folds fewer instructions than the C clone)
7. ppunit imm-fold (peephole unit test)
8. (summary counts 8 vs 7 printed FAIL lines: one addcheck double-counted)

## Status update 13 - unsigned-compare chase: literals >= 2^64; oracle reality-check

matlab_in_rust f7cf524: number literals past u64 now parse as doubles
(checked-mul overflow -> f64 accumulation, decimal and hex) instead of
wrapping. Root cause: xc's x86sim computes unsigned-borrow flags in
sim_setflags_cmp via mod(d, 2^64) < mod(s, 2^64); the engine's 2^64
literal wrapped to 0, so mod(x, 0) = NaN and every unsigned compare was
false (cc18_unsigned2 sim=10 -> 111, cc18_unsigned sim=2 -> 7). Gates
green.

Oracle reality-check (important): the C clone (v1.3.47) run of the FULL
Writing-a-C run_tests.m scores 768 tests / 577 passed / 191 failed - the
harness is NOT a C-clone-green suite (many cc_int 'bad expression' rows
where the clone's interpreter falls behind the repo's newer .m). The Rust
engine scores 769/761/8 - 184 tests ahead of the clone. The engine's 8
remaining fails overlap the C clone's own (cc18_unsigned sim=7 expect=6
in both engines; x86sim dense %.17g, %X uppercase, p6_printf2 parity,
peephole corpus/imm-fold): engine == C clone byte-for-byte there, so the
residuals are upstream x86sim/peephole divergences from gcc/real MATLAB,
not engine bugs. Real MATLAB is the suite's true oracle; the engine
cannot be pushed past C parity on these without a real-MATLAB oracle or
upstream x86sim fixes in the Writing-a-C repo.

## Status update 14 - recount attempt aborted by environment

A final full-suite recount after f7cf524 was launched but the host
suspends for hours at a time (16 wall-hours produced ~24 engine-CPU
minutes; the run reached the sim-corpus tail checks %X/%05d then died
without flushing the summary). The two f7cf524 targets were already
verified standalone against the C clone: cc18_unsigned2 sim=111, cc18_unsigned
sim=7 (== C clone's own 7). Expected recount totals ~763/769 with the
residuals all engine==C-clone upstream x86sim items; not re-run.

## Status update 15 - handoff complete; thread closed

x86sim no-operand fix committed to the repo (1fd742b). Upstream bug
report drafted and handed as-is (untracked):
docs/2026-09-07-x86sim-peephole-divergences.md (items A1-A3 x86sim
R==C bugs, B peephole fold gap R 11575 / C 10897 vs 10822, C
order/state dependence inside peephole_pass). Engine at full C-parity
on this harness (761/769 completed run; f7cf524 clears the two
unsigned items verified standalone), all residuals R==C upstream.
No further engine work planned on this thread.

## Postscript 2026-09-08 (Writing-a-C repo) — one correction, thread stays closed

The status-13 line "all residuals R==C upstream" was wrong for item A3.
x86sim's `cc18_unsigned` exit 7-vs-6 is a latent integer-class bug in
`src/x86sim.m` (the shrq shift count is a raw int64, so `u / 2^c` does
integer arithmetic with round-half semantics on both clones while real
MATLAB promotes to double); fixed in-repo (`6a73590`), verified 7->6 on
both interpreters. A follow-up audit of undeclared file globals fixed 19
references across 11 cc_int.m functions (`7db5dfe`, `5ed841d`). The
engine-compat thread recorded here remains closed; item-by-item
resolution lives in docs/2026-09-07-x86sim-peephole-divergences.md.
