# Over-engineering audit — 2026-09-02

Whole-repo scan (ponytail-audit): 44 tracked files, ~7k lines of `.m`, 463 corpus
`.c`. Findings are ranked biggest cut first. Nothing in this pass was applied.

## 1. `delete:` src/cc_int.m.bak — 3300 lines

Snapshot of `cc_int.m` from before double support (`e2b4c8d`), superseded and
already recoverable from git history. Replacement: nothing.
`[src/cc_int.m.bak]`

## 2. `yagni:` `'interpret'` flag — src/mex_run.m:31

Accepted and documented ("reference track (TBD)"), but no branch implements it:
it silently falls through to the `'compile'` path. No caller in this repo or in
`/d/Projects/codes/MATLAB_in_C`. (`'gcc'` and `'compilecheck'` are live —
`mex_cmd.c:377`.) Replacement: drop the disjunct.
`[src/mex_run.m]`

## 3. `shrink:` three copies of one equality helper

`cv_eq` is verbatim identical in `src/x86sim.m:2157` and `src/peephole_pass.m:491`;
`pp_eq` (`src/peephole_pass.m:485`) is `cv_eq(a, double(s))`. Replacement:
`pp_eq` → `cv_eq(a, double(s))`, keep one `cv_eq` per file (or promote to
`src/cv_eq.m`). `[-8 lines]`

## 4. `shrink:` sim_dtrunc — src/x86sim.m:1774

Wraps `fix(x)` in an isnan/isinf guard; `fix` already maps NaN→NaN, ±Inf→±Inf.
Replacement: `v = fix(x)`. Verify on the clone before cutting — every other guard
in that file is clone-driven. `[-6 lines]`

## 5. `shrink:` four shell runners, 151 lines, same driver 4×

`tests/run_double_regression.sh`, `tests/run_mex_run_gcc.sh`,
`tests/run_mex_run_smoke.sh`, `tests/run_mx_smoke.sh` each re-implement
`$M -e "addpath('…')"` + `^Error` grep + pass/fail counter, and hardcode
`M=/d/Projects/codes/MATLAB_in_c/matlab.exe` plus the repo path. Replacement: one
`tests/_runner.sh` holding the driver, four corpus lists.
`[-40 lines, -3 copies of the absolute paths]`

## 6. `delete:` five dated one-shot process docs, 1318 lines

- `docs/2026-08-10-xc-matlab-port-plan.md` (444)
- `docs/2026-08-15-fix-plan.md` (185)
- `docs/2026-08-16-mex-support-plan.md` (279)
- `docs/2026-08-16-compiler-optimization-plan.md` (311)
- `docs/2026-08-15-codebase-review.md` (99)

Each planned work that `PROJECT_STATUS.md` already records as done. Keep the
optimization plan — `peephole_pass.m`'s header documents all 11 peephole rules by
reference to it. Replace the rest with the status doc. `[-1000 lines]`

## Lean already

- No unused subfunctions — all 200+ helpers are reached.
- No unused globals — 0 of 140 declared.
- No single-implementation abstractions, no factories, no dead config.
- No dependencies; no hand-rolled stdlib except the clone-workaround wrappers
  (`cv_of` / `cv_char` / `cv_eq`), justified by
  `docs/2026-08-10-matlab-clone-bug-report.md`.
- `mx_ref.c` ↔ `sim_mx*` and `mex_run` ↔ `mex_run_gcc` are deliberate A/B tracks
  (compile+simulate vs. real gcc reference), not duplication.

## Net

`-3300 lines dead file, ~-55 lines code, ~-1000 lines process docs, -0 deps.`

Scope: over-engineering and complexity only. Correctness, security, and
performance were out of scope for this pass.
