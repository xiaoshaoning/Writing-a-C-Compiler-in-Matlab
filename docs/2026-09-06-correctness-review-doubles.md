# Correctness review — cc_int/x86sim double support (differential vs gcc) — 2026-09-06

Outcome of the planned **normal (non-ponytail) correctness pass** over the
compiler's double/SSE path. Scope: differential execution of small C programs
compiled by `cc_int` + run on `x86sim`, cross-checked against the same source
built by real gcc (stdout + exit code). Two real bugs found. Local MATLAB
used: `D:\Projects\codes\MATLAB_in_C\matlab.exe` (the project's own runtime
clone). Working dir: `/d/tmp/dprobe`.

## Bug A (root-caused, fix validated): dense double literals are corrupted by sim_num64

**Symptom.** Compiled programs print wrong least-significant digits for any
double literal whose IEEE pattern is >~2^53 as a magnitude (nearly every
real fraction). Repro program `pfmt.c`:

```c
double x = 0.1;
printf("%.17g\n", x);     // sim: 0.099999999999994316   gcc: 0.10000000000000001
printf("%.17g\n", 123.456789);  // sim: ...00348         gcc: 123.456789
```

`%f`@6 / `%e`@6 / `%g`@6 are unaffected (too few digits to reveal it); only
high-precision (`%.*g` with many sig figs, and any print that rounds near the
mantissa's low bits) shows corruption. Live division `1.0/3.0` printed at
`%.19g` is corrupt the same way *through the result's own stored `.quad`*.

I verified every later stage is exact in isolation (clone `10/3` is correct;
`sim_d2bytes`→`sim_bytes2d` round-trips `10/3` exactly; `sim_bits2d`
reconstructs bit-identically; clone `sprintf('%.17g',0.1)` is correct). So the
loss is earlier, at **literal materialization**.

**Root cause.** `x86sim.m: sim_num64` parses a 64-bit hex literal by
accumulating `v = v*16 + d` **in the double domain** to stay under 2^53 for
arithmetic, but a full-width IEEE pattern like 0.1's (`0x3FB999999999999A` =
4591870180066957722) spans ~62 significant bits, so each `v*16+d` past 2^53
rounds and the low ~9 mantissa bits are lost. Measured:
`sim_num64('0x3FB999999999999A')` → `4591870180066957312`,
true `4591870180066957722`, **error = 512**. Double constants that happen to be
magnitude-exact (2.5, 3.0, 10.0 — sparse, low bits zero) survive, which is why
the whole existing `d*` corpus passes despite the bug.

**Validated fix.** Split the 16 hex digits into high/low 32-bit halves
(hi32 = first 8 nibbles, lo32 = last 8), combine `hi32*2^32 + lo32`. Both
halves < 2^32, product < 2^63, so it is exact. Probe `fixcheck.m` reproduces
0.1's pattern with **diff 0**.

**Scope comment.** `%a` (hex float to string) is also unsupported in the sim
(gap, prints `a `) — out of the documented feature set, noted only.

## Bug B (reproduced, cause not yet traced): global doubles load as zero under x86sim

**Symptom.** A program operating on **global** doubles computes garbage / 0 /
NaN where locals work. Repro `pza.c`:

```c
double g=10.0, h=3.0;
int main(){ printf("%.17g %.17g %.17g %.17g\n", g+h, g-h, g*h, g/h); }
// sim:  0 0 0 nan       gcc: 13 7 30 3.3333333333333335
```

Every emitted `Warning: Divide by zero.` is the sim's own guard firing because
the divisor reads as 0; locals in `pfmt.c`/`p1_div` at least carry a
near-correct value, so global `.quad` doubles resolve to **0**, distinct from
Bug A's low-bit rounding. Suspected location: the data/`.quad`+symbol resolution
and/or `leaq g(%rip); movsd (%rax),%xmm0` addressing for globals, not the
arithmetic itself (division works for locals). A follow-up trace through
pass 2 data-emit + `movsd` mem operand is the next step.

## Methodology / notes

- Differential driver: compile each probe with `cc_int`, run on `x86sim`; build
  the identical source with `gcc -lm`, run natively; compare trimmed stdout +
  exit code. Manual (loops over probe dir), not committed.
- The sim emits `Warning: Divide by zero.` lines to stdout for IEEE-divbyzero
  where gcc is silent — this pollutes differential stdout comparison and is
  arguably its own (minor) behavioral divergence worth reviewing separately.
- Neither bug is caught by the current suite because its double corpus uses
  only magnitude-exact literals and omits global doubles.

## Status (updated 2026-09-06)

Bug A is **fixed** - see `docs/2026-09-06-correctness-review-doubles-deep.md`.
Two defects stacked: (1) `sim_num64`'s double-domain accumulator rounded
>2^53 literal patterns; (2) `printf`/`mexPrintf` passed the >2^53 register
pattern through `double()` before `sim_bits2d`, corrupting high-precision
float output even for exact values. Both are fixed in `src/x86sim.m`
(commit 5c31063) on the MATLAB_in_C v1.3.47+ runtime; pfmt/divprint now
match real gcc byte-for-byte and the double corpus is 10/10.

## Remaining

**Bug B - .quad numeric globals - FIXED (commit 6228ea1).** Root cause was
in x86sim's pass-2 data emit: it called sim_store_bytes(addr, v), which
writes numel(v) == 1 bytes, so a scalar .quad stored only its low byte
(100000 -> 160; .quad double patterns read as 0). Now stores the directive
width via sim_storeN. gint '7 100000', pza globals, and pz 10/3 all match
gcc on v1.3.47.

**Still open, separate from Bug A/B: the 4th+ double in one printf call is
mis-rendered.** With all values fixed, `printf("%.17g %.17g %.17g %.17g",
gh,g2,g3,g/h)` renders the arg at integer position 4 (the first that comes
from the simulated stack, ai>=3 -> sim_load64(rsp+32+8k)) with the low
mantissa bits lost (3.33...4849 instead of ...3335); calls with 1/2/3
doubles are exact. Not yet traced; likely the multi-arg float printf
shim/stack read, not value transport.
