# Codebase Review — 2026-08-15

A review of the full codebase (both tracks, test harness, docs, git history) on
the target runtime `v1.3.21`.

## Verified working state

- **Full suite passes 105/105** on the target runtime (`v1.3.21`, also
  verified on the previous `v1.2.51`) via the documented
  `matlab.bat tests/run_tests.m`.
- **`cc_int.m` verified end-to-end**: compile → MSYS2 gcc → exit code 2.
- All 56 `.c` corpus files are covered by `run_tests.m`; every expected exit
  code/stdout is cross-checked against the reference `xc.c` build.

## Strengths

- **Rigorous port discipline.** The `xc.c → xc.m` translation is careful and
  well-commented: the two-space memory model, 0-based-slot/1-based-pc
  conventions, and the byte↔word scaling table are all documented inline, and
  the `JZ`/`JMP` backpatch math (`ti+3`, `ti+1`) checks out exactly against the
  C original.
- **Defense-in-depth test design.** `probe_primitives.m` re-gates every runtime
  primitive the port depends on *before* each run — smart given the custom
  MATLAB clone has a long bug history (BUG-1…18, DIV-5…10 tracked in the bug
  report).
- **Parity is real.** `-s` dumps byte-identical modulo absolute addresses,
  `hello.c` stdout byte-exact, and the post-parity additions (block comments,
  arrays, initializers, `void`, multi-read) are all in the suite.
- Docs (plan, status, bug report) are unusually complete and honest about
  dialect gaps.

## Issues found

### 1. Documentation drift (counts are stale)

- `README.md:20` and `README.md:82` say the harness is **"94 checks"** — it is
  105.
- `docs/PROJECT_STATUS.md:29` says **"8-case lexer selftest"** — the code has 9
  (`lex_selftest` prints `9 cases`; block comments were added in post-parity).
- `README.md` links to `docs/2026-08-10-matlab-clone-bug-report.md`, which is
  **gitignored** ("internal, not for the public repo") — that is a dead link
  for anyone who clones.

### 2. Documented `-batch` invocation is broken

`tests/run_tests.m:6` and the README `-batch` examples document
`matlab.bat -batch "addpath('.'); addpath('tests'); run_tests"`. This fails on
the runtime with `Unrecognized function or variable 'addcheck'` — the script's
local function is not resolvable in that mode. Only `matlab.bat tests/run_tests.m`
(file-as-argument) works. Either fix the comment/README or report it as a clone
quirk.

### 3. `&` (address-of) is silently lax

`xc.m:1177`. The post-parity no-op branch drops xc.c's hard `"bad address of"`
error. It is correct for all lvalues (locals end in `LEA`, globals in `IMM`,
derefs/indices end in `LC`/`LI`), but `&(1+2)` or `&(a=b)` compile silently and
produce the value instead of the address — a user-error masking risk. Also
note the check reads `text(ti+1)`, which for a bare `IMM` unit is the *operand
slot* — data-dependent.

### 4. `cdivmod` with a zero divisor returns 0 silently

Instead of erroring (the reference dies with SIGFPE). Untested edge case in
the VM.

### 5. Small code-level nits

- `cc_int.m:36` hardcodes `.file "return_2.c"` regardless of the input
  filename; `regexp 'return'` also matches lines like `return2;` (yielding an
  empty constant) and any identifier containing "return". Cosmetic for the
  intended single use, but the regex is looser than the comment implies.
- `data_top` (`xc.m:17,36`) is declared/initialized but never used — dead
  state.
- `sys_open` never shrinks the fd registry (`sys_close` leaves the slot), so
  16 open/close cycles → hard `fail('OPEN: too many open files')`. Fine for the
  corpus, but it is a leak-by-design.
- `seed_symbols` docstring (`xc.m:772`) says "'void' becomes Char" — stale; it
  is now token 165.
- Unsupported array initializers fail with the cryptic `"bad global
  declaration"` (token 142 hits the `token ~= Id` branch) rather than a
  targeted message.

### 6. Housekeeping

- The working tree has an uncommitted `README.md` modification (runtime bump
  to v1.3.21) — commit it.
- `docs/2026-08-10-xc-matlab-port-plan.md:4` top-of-file banner says "suite
  green 95/95" — out of date (105/105). The phase notes' historical counts
  (94/94, 95/95) are fine.

## Bottom line

A well-executed, well-tested port — the interpreter track is genuinely complete
and parity-verified, and the assembly track works end-to-end. The issues are
almost entirely documentation drift plus a handful of minor robustness gaps
(the `-batch` harness path is the only one that is actually broken today).
Highest-value fixes: update the check counts, fix the `-batch` documentation,
and commit the pending README change.
