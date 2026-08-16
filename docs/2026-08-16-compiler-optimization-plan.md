# Compiler Optimization Plan — 2026-08-16

Optimizing `src/cc_int.m` for **generated-code quality** (the primary goal:
the emitted x86-64 should be smaller and faster), with **code clarity** of
the compiler itself as the second goal. Both safe local passes and
structural work are in scope. The **727-check suite stays green** at every
step, and `src/x86sim.m` is extended as needed so the gcc-free track keeps
agreeing with gcc.

## Goals & success criteria

1. **Generated-code quality** — fewer instructions, smaller `.s` files,
   less stack traffic, at least as fast at runtime. Targets:
   - Total corpus instructions: **8,689 → ~6,000** (≈30% reduction).
   - Corpus `.s` bytes: **220,726 → ~160,000**.
   - `pushq`+`popq`: **2,391 → ~1,200** (halve the stack traffic).
   - `leaq` count: **838 → ~500** (kill the redundant
     `leaq …; movq (%rax),%rax` pairs).
   - All measurements via a permanent instruction-counting harness in the
     suite (below); every optimization must improve the count or be cut.
2. **Correctness** — every phase lands with the 727-check suite green
   (gcc-gated exits, x86sim exits, cross-track exit + stdout parity,
   output parity). No behavior change: identical exit codes and stdout.
3. **Clarity** — the compiler's structure improves as a side effect of the
   passes; the single-file layout is kept (a documented project trait) but
   each pass is a well-commented, isolated function.
4. **x86sim parity** — any new instructions the optimizations emit are
   added to the simulator (and the corpus/parity checks still pass).

## Baseline (measured 2026-08-16)

Compiler corpus: 286 `cc2_*`–`cc18_*` programs.

| Metric | Baseline |
|---|---|
| Total emitted instructions | 8,689 |
| Total `.s` bytes | 220,726 |
| `pushq` / `popq` | 1,256 / 1,135 (27.5% of all instructions) |
| `leaq` | 838 |
| `movq` | 2,920 (33.6% — many are operand shuffles) |
| Corpus compile time | 13.2 s (285 programs, ~46 ms each) |
| hello.c | 106 instructions, 2,265 bytes, 0.05 s compile |

The dominant cost is the stack-based expression discipline: every binary
op and every assignment pushes/pops operands, and every local load emits
a `leaq` + `movq (%rax),%rax` pair. The structural work (register
allocation) is where the big wins are; the local passes are the safe,
incremental foundation.

## The regression gate

- `tests/run_tests.m` — the full 727-check suite runs after every phase
  (gcc-gated group, x86sim group, parity groups, output parity).
- A new permanent suite group: **instruction-count regression** — the
  harness compiles the corpus, sums instructions, and asserts the count
  stays at or below a recorded ceiling (so a future change cannot
  silently bloat the output).
- The gcc-built exes must produce identical exit codes and stdout
  (already asserted). The x86sim track must keep agreeing (extend it when
  a new instruction appears).

---

## Phase A — Measurement harness (foundation)

Build the tooling that every later phase relies on.

- [ ] Add a `count_instr()` helper (parse a `.s`, count tab-led
      mnemonic lines, per-mnemonic breakdown) to the suite or as a small
      standalone script.
- [ ] Add the **instruction-count regression** group to `run_tests.m`:
      compile the `cc*.c` corpus, sum instructions, assert ≤ the recorded
      ceiling (start at 8,689, ratchet down per phase).
- [ ] Add a per-program spot check: assert specific programs stay under
      instruction budgets (e.g., hello.c ≤ 106 initially, tightened per
      phase).
- [ ] Add the corpus compile-time measurement (optional group: `SKIP`
      if slow).
- [ ] Verify the harness itself is cheap (the corpus compile is ~13 s —
      the count adds little).

## Phase B — Peephole pass (safe local, first big easy win)

A single linear pass over the emitted instruction list that removes
obvious dead code. Runs after codegen, before output.

- [ ] Remove no-ops:
      `addq $0`, `subq $0`, `imulq $1`, `movq %rax, %rax`,
      `addq $0, %rax` after a `movq`-of-immediate (the pointer offset 0
      case).
- [ ] Remove `jmp .L` when `.L:` is the immediately following label.
- [ ] Collapse `jcc .L1; jmp .L2; .L1:` → invert the condition and jump
      to `.L2` directly (when `.L1` is otherwise unreferenced).
- [ ] Remove a `pushq %rax; popq %rbx` pair → `movq %rax, %rbx`
      (register move without the stack) — only when rbx is dead at that
      point (safe within the current codegen discipline: rbx is a scratch
      between statements).
- [ ] Remove a trailing `movq %rax, %rbx; …; movq %rbx, %rax` round-trip
      when the destination is unused.
- [ ] Fold `movq $N, %rax; addq $M, %rax` → `movq $N+M, %rax`
      (and the subq/imulq variants).
- [ ] Fold `cmpq $0, %rax; sete %al; movzbl %al, %eax` patterns where the
      flags are already known (defer to Phase D if ambiguous).
- [ ] Iterate the pass to a fixed point (a removed instruction may expose
      another).
- [ ] **Gate:** 727-suite green; instruction count drops (expect the
      first ~5–10%).

## Phase C — Address-mode simplification (local, big win)

The single most common pattern is a load of a local/global:

```
leaq -8(%rbp), %rax      ; or: leaq name(%rip), %rax
movq (%rax), %rax        ; / movzbl (%rax), %eax
```

This is `load X` — the `leaq` is pure overhead.

- [ ] Peephole: `leaq K(%rbp), %rax` immediately followed by
      `movq (%rax), %rax` → `movq K(%rbp), %rax`.
      Same for `movzbl`/`movsbl` (byte loads) and the global form
      `leaq name(%rip), %rax; movq (%rax), %rax` →
      `movq name(%rip), %rax`.
- [ ] Peephole: the assignment-store side:
      `leaq K(%rbp), %rax; pushq %rax; <rhs>; popq %rbx; movq %rax, (%rbx)`
      → `<rhs>; movq %rax, K(%rbp)` (the LHS address push/pop eliminated
      when the RHS doesn't need the LHS — verify the `x = x + 1` case
      where the RHS reads the same variable!).
- [ ] The `a[i]` indexing: `leaq base, %rax; pushq %rax; <idx>; …;
      popq %rax; addq %rbx, %rax` — keep (the base must be preserved
      across the index eval) but fold the `leaq`+`addq` when the index is
      a constant: `leaq K(%rbp), %rax; … imulq $8; addq %rbx, %rax` →
      the constant offset folded into the address.
- [ ] The row-decay case and the struct-member case
      (`leaq 8(%rax), %rax` — fold into the following load if any).
- [ ] **Gate:** 727-suite green; `leaq` count drops sharply (838 → ~500);
      instruction count drops (expect another ~10%).

## Phase D — Constant folding (local)

Fold constant subexpressions so the emitted code computes them at compile
time.

- [ ] Fold binary ops on two immediates: `2 + 3`, `10 * 4`, `1 << 2`,
      `7 % 3`, `-5 / 2` (C truncation) → a single `movq $N`.
- [ ] Fold immediate ops into the preceding `movq $N`:
      `movq $5, %rax; addq $3, %rax` → `movq $8, %rax`
      (already listed in Phase B; make it complete for `-`, `*`, `&`,
      `|`, `^`, `<<`, `>>`).
- [ ] Fold `movq $N, %rax; cmpq $M, %rax` → `cmpq $M, $N`-style — only
      when it reduces instructions (compare against the immediate:
      `cmpq $M, %rax` stays; the fold is in the setcc value).
- [ ] `0 * x`, `x * 0`, `0 + x` → the other operand (when the non-folded
      operand is a simple load — safe only when no side effects).
- [ ] **Gate:** 727-suite green; count drops (expect a few %; the corpus
      is small but constant-heavy).

## Phase E — Structural: stack-traffic reduction (the big win)

The push/pop discipline: every binary op does
`pushq %rax; <right>; movq %rax, %rbx; popq %rax; op %rbx, %rax`. The
left operand is spilled because the right's evaluation clobbers rax (and
rbx). Two sub-phases:

### E1 — Targeted codegen improvement (moderate risk)

When the right operand is a **simple value** that cannot clobber rbx
(an immediate `movq $N, %rax` or a single `movq K(%rbp), %rax` load),
keep the left in rbx without the stack:

```
movq $2, %rax; pushq %rax; movq $3, %rax; movq %rax, %rbx; popq %rax; addq %rbx, %rax
→ movq $2, %rbx; movq $3, %rax; addq %rbx, %rax
```

- [ ] In `parse_term`/`parse_additive`/`parse_shift`/bitwise/logical:
      when the right parse is known-simple, emit the left into rbx
      directly and skip the push/pop.
- [ ] Same for the comparisons (`cmpq %rbx, %rax` — the left in rbx, no
      push/pop when the right is simple).
- [ ] The assignment RHS `popq %rbx` patterns (the LHS address) — fold
      per Phase C.
- [ ] **Gate:** 727-suite green; `pushq`+`popq` drops (expect 2,391 →
      ~1,500). x86sim untouched (same instructions, fewer of them).

### E2 — A small register allocator (structural, the largest change)

A linear-scan pass over the emitted code that assigns live values to the
free registers (rcx, rdx, r8–r11 — rax is the value register, rbx the
scratch, rbp/rsp the frame) instead of the stack, only when the value's
live range doesn't cross a call.

- [ ] Identify push/pop pairs that frame a live value; replace with a
      register home when one is free at that point.
- [ ] Handle the call barrier: values live across a `call` stay on the
      stack (or the callee-saved set — the compiler's own functions
      clobber rbx/r8–r11; the shims preserve rbx — document the ABI).
- [ ] Reuse r8–r11 for the operand shuffles
      (`movq %rax, %r8; <right>; addq %r8, %rax`).
- [ ] The `movq %rax, %rbx; popq %rax; op %rbx, %rax` sequences →
      register-based equivalents.
- [ ] Keep the emitted set within what x86sim understands, or extend
      x86sim in Phase G.
- [ ] **Gate:** 727-suite green (the real gate: the gcc-gated exits and
      the x86sim parity both rerun); `pushq`+`popq` → ~1,200; total →
      ~6,000.

## Phase F — Code clarity

The compiler is a 2,600-line single file; the passes should be extracted
into well-named, isolated local functions with doc comments, and the main
`parse_*` chain should stay readable.

- [ ] Extract the peephole/const-fold/address-mode passes into named
      functions (`peephole_pass`, `fold_constants`,
      `simplify_addresses`, `alloc_registers`) with a one-line contract
      and a comment on what each pattern rewrites.
- [ ] Group the parse functions into sections with a header comment
      (already partially done — tighten it).
- [ ] Add a top-of-file "pipeline" comment: parse → codegen →
      optimize → emit.
- [ ] Add unit-ish checks for each pass: a tiny `.s` fixture with the
      pattern, assert the rewritten output (a new suite group or the
      existing harness).
- [ ] **Gate:** the suite still passes after the refactor (no behavior
      change — pure moves); keep `git` history granular so each rename is
      reviewable.

## Phase G — x86sim extension

- [ ] Audit every pass's new instruction forms; the current sim covers
      the emitted set (281/281) — new forms are unlikely but possible
      (e.g., if the allocator uses `r8d`, `movslq`, or `lea` with a
      scaled index).
- [ ] For each new mnemonic/form: add to the sim's mnemonic table +
      executor + a corpus check.
- [ ] Keep the sim's instruction-count parity group green.
- [ ] **Gate:** 727-suite green (the x86sim groups exercise the sim).

## Out of scope / future work

- Runtime-library codegen (the shims) — they're already minimal and
  ABI-constrained.
- Optimization of the interpreter track (`xc.m` — different project).
- Cross-function inlining, loop unrolling, SSA — far beyond the current
  architecture; revisit after E2.
- Real-MATLAB performance tuning (the clone is the target).

## Risks & notes

- **The suite is the oracle.** Every phase gates on it; a pass that
  doesn't reduce the count or improve clarity gets cut.
- **`x = x + 1`-style aliasing** — the LHS address and the RHS reads can
  overlap; Phase C/E rewrites must not move the load of `x` across the
  store. Test explicitly.
- **Flag semantics** — `cmpq` sets flags read by the immediately
  following `setcc`/`jcc`; peepholes that reorder must preserve this
  (Phase B's `jcc .L1; jmp .L2` collapse and the compare folds).
- **The 16-byte frame rounding** — keep (the Win64 shims align
  themselves, but the frame size rounding is a cheap safety margin).
- **git hygiene** — one commit per phase, each with its measurement
  delta in the message, so the instruction count can be audited over
  time.
