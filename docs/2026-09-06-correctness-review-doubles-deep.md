# Correctness review (deep round) — x86sim data/double/global handling — 2026-09-06

Follow-on to `2026-09-06-correctness-review-doubles.md` after trying to fix Bug A
and tracing Bug B. The differential probes exposed a **cluster of genuine
defects in x86sim's data/immediate/numeric handling**, not a single one, and —
critically — a **validation environment problem**: the local `MATLAB_in_C`
clone (`matlab.exe`) cannot represent or print arbitrary 64-bit values or
int64 above 2^53, so its `%d`/`%g`/`fprintf`/`fwrite(...,'int64')` all report
garbage for the very patterns being diagnosed. That makes most in-place numeric
verification untrustworthy and is itself a caveat for every value-derived test.

## Bug A refined — double literals corrupt: emission-side, not sim_num64

Investigated all x86sim primitives individually by slicing them verbatim from
the file and testing separately (all exact):
- `sim_d2bytes`/`sim_bytes2d` round-trip `0.1`, `0.3`, `123.456789`, `2.5`,
  `10/3` bi-exactly in the file's own code.
- `sim_bits2d` decodes patterns for `0.1`, `10.0`, `123.456789`, `1.0` exactly.
- Clone `10/3` and `sprintf('%.17g', 0.1)` are correct.

Yet integrated runs corrupt every dense literal (`0.1` prints
`0.0999...4316`; `123.456789` gains trailing digits) while register-computed
divisions stay bit-correct (`1.0/3.0*3.0 == 1.0`). Repro discriminator:
`0.1 == 1.0/10.0` is FALSE in x86sim, TRUE under gcc.

cc_int emits a local double literal as a **`movabsq $0x<ieee-pattern>,%rax`**
immediate — i.e. a raw >2^53 integer bit-pattern smuggled through the register/
immediate model, then `movq %rax,%xmm0` + `sim_bits2d`. Every primitive is exact,
so the corruption is at the boundary where an arbitrary int64 bit-pattern must
survive being an *immediate operand in a cell / register store*. The repo's own
header notes "the clone cannot hold arbitrary 64-bit patterns in its numeric
model" — this literals path is exactly that unsupported case.

An int64-nibble rewrite of `sim_num64` was implemented and validated standalone
(as a `.m` replicant) against Python ground truth on 10 patterns (dense, signs,
extremes) — all exact — **but in-file it changed nothing**, and byte-exact
`fwrite` read-back of the supposed int64 returned wrong low bytes, confirming
the host itself round-trips/int64-stores lossily regardless. So the fix was
reverted (tree clean) rather than shipped unverifiable.

**Recommended direction (needs the maintainer's verified host):** have cc_int
materialize double literals the supported way the working corpus already uses —
emit them as `.quad <pattern>` **data** loaded via `movsd <sym>(%rip),%xmm0`
(the exact byte-store/byte-load path proven lossless), instead of
`movabsq $<imm>,%rax`. That routes around the int-immediate limitation rather
than fighting it.

## Bug B + a third defect — `.quad` globals read back wrong

Both integer and double global values are affected:
- `long gl=100000;` prints **160** (100000 & 0xFF) under x86sim, `100000` under
  gcc; `int gi=7` is fine (7 < 256, masks a low-byte-only read). Assembly emits
  `gi/gl` both as `.quad` and loads both via `movq gl(%rip),%rax` identically.
- `double g=10.0, h=3.0;` computed as `0 0 0 nan` (operands read as zero).

Pattern: sim is reading only the low byte (or losing all but low bits) of some
`.quad` global data, so it's a **data-layout/`.quad`-store-or-movq-load width
defect**, distinct from Bug A's immediate model. Masked in the corpus because
global constants there are < 256 / byte-sized.

## Repro corpus (all in `D:\tmp\dprobe\`, differential vs real gcc)

- `pfmt.c` / `p1_div.c` — dense literal + division prints (Bug A).
- `pv.c` — `0.1 == 1.0/10.0` discriminate (Bug A, value level).
- `gint.c` — `long gl=100000` prints 160 (Bug B, width).
- `pza.c` — global doubles compute to 0 / nan (Bug B).

## Environment caveat

`matlab.exe` (MATLAB_in_C clone) `%d`/`%g`/`fwrite int64` for >2^53 values and
its own double formatting were found unreliable for diagnostics; all numeric
conclusions above were cross-checked where possible against Python ground truth
or integer-only/allowed-value compares that the sim handles reliably.

## Status (updated 2026-09-06, after v1.3.47)

Bug A splits into TWO separable defects; v1.3.47 (MATLAB_in_c) fixed the
runtime-transport half:

1. **VALUE transport — FIXED in runtime + needs sim_num64.** The clone
   runtime degraded exact int64 > 2^53 at identity-conversion/index-read/
   write boundaries; v1.3.47 fixed those (doc 6.9, all but block-write /
   slice-read / grow-from-empty). With that build, a nibble-exact rewrite of
   `sim_num64` (double-domain `v*16+d` rounded the pattern past 2^53) now
   carries the exact pattern to %rax/%xmm0. `src/x86sim.m` carries this fix;
   value-level parity confirmed: `pv.c` exit 0 (`0.1 == 1.0/10.0`, matches
   gcc), dsmoke/dcmp/dneg/d2and exit codes unchanged.
2. **HIGH-PRECISION float PRINT - now FIXED in this commit.** The remaining
   wrong digits were NOT the literal/value but the sim's printf-arg
   transport: sim_printf's first three args were passed as
   `double(regs(3/9/10))`, rounding a >2^53 double-pattern register before
   sim_bits2d. Passing the raw int64 regs fixes it (matlab sprintf of the
   exact decoded double is correct). Committed here with sim_num64.

After both fixes on MATLAB_in_c v1.3.47: pfmt and divprint match real gcc
byte-for-byte (incl. %.17g of 0.1/pi/1/3/2/7); pv.c exit 0; the double
corpus differential (dsmoke/dcmp/dmore*/dneg/d2and/cc10_cadd/dmath) is
10/10; fmtb2 %d/%x/%s/%c/width/precision unchanged; mxmath(%.6f) and
mxchar(%s) via mex_run unchanged. These fixes require the v1.3.47+ runtime
(older runtimes re-round the exact int64 on reg/index writes).

Bug B (`.quad`-global width/load, `long gl=100000` -> 160, global doubles 0)
and the low-byte `.quad`-global issue remain separate and untraced; not
re-checked against v1.3.47 yet.

Required runtime for the sim_num64 fix to take effect: MATLAB_in_c build
v1.3.47+ (earlier runtimes re-rounded the large int64 in conversion/index
writes, which the committed double-domain sim_num64 happened to mask). See
MATLAB_in_c `docs/MATLAB_RUNTIME_BUGS.md` entry 6.9.
