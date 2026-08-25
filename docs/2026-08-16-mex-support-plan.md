# MEX Support Extension Plan — doubles, the mxArray ABI, and a mex runner

- Status: plan (draft)
- Date: 2026-08-16
- Project: Writing-a-C-Compiler-in-Matlab
- Scope: extend `xc.m` (interpreter), `cc_int.m` (compiler), `x86sim.m`
  (simulator) and `tests/run_tests.m` (harness) so the project can
  **compile and run MEX-style C sources**, including full `double`
  numeric support.
- Related: `docs/2026-08-10-xc-matlab-port-plan.md`,
  `docs/2026-08-16-reference-cross-check.md`, `docs/PROJECT_STATUS.md`

---

## 1. Goal

A MEX file is a C function

```c
void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]);
```

compiled to a shared library, loaded by a MATLAB host, and called with
`mxArray*` handles. This plan makes the project able to:

1. **compile** a MEX source to x86-64 assembly with `cc_int.m`,
2. **run** it gcc-free through `x86sim.m` (and interpret it through `xc.m`),
   with the `mx*` API emulated,
3. **validate** it with the existing cross-track parity methodology
   (xc-track vs cc_int+x86sim-track vs a gcc-gated reference build),
4. and thereby act as an independent oracle for a MATLAB host that plans
   native MEX loading (e.g. the MATLAB-clone interpreter in C).

Two capabilities are prerequisites and are the bulk of the work:

- **A. Full C `double` (IEEE-754) numeric support** in both tracks and the
  simulator. Today both tracks are integer-only (no `double`/`float`
  keyword; all `double` hits in the sources are MATLAB-side conversions).
- **B. An `mxArray` ABI plus an `mx*` API library** implemented twice:
  as C source (compilable by `cc_int.m` once doubles exist) and as MATLAB
  stubs (callable from `xc.m`'s syscall layer and `x86sim.m`'s shim
  layer), so a `mexFunction` runs end-to-end without a real DLL.

## 2. What exists today (verified)

- `xc.m` (2,427 lines): C interpreter — lexer, recursive-descent parser,
  38-opcode stack VM (`LEA IMM JMP CALL JZ JNZ ENT ADJ LEV LI LC SI SC
  PUSH OR XOR AND EQ NE LT GT LE GE SHL SHR ADD SUB MUL DIV MOD`), syscalls
  (`open/read/close/printf/malloc/exit`). Types are `CHAR=0, INT=1, PTR=2`;
  memory is a 64-bit word array; all C values are 64-bit.
- `cc_int.m` (2,996 lines): C → x86-64 AT&T assembly, Norasandler parts
  1-17, plus `printf`/`malloc`/`memset`/`memcmp`/`exit`/`open`/`read`/
  `close` via **Win64-ABI adapter shims** (`__cc_<name>_<nargs>`), structs
  by value, function pointers, `goto`, casts, local structs/enums.
- `x86sim.m` (1,197 lines): gcc-free simulator — instruction table
  (`movq movl movzbl movsbl movb leaq pushq popq addq subq imulq andq
  sarq cmpq testb cqto idivq sete..setae shrq divq jmp jz jnz call ret
  xorl`), flags, memory, stack.
- `tests/run_tests.m` (903 lines, 669 checks): 10 groups; group 10 runs
  the shared corpus through BOTH tracks and asserts exit-code/stdout
  agreement (187 programs on exit codes, 53 on full stdout).

The Win64 shim mechanism is the key existing pattern: external calls
(`printf`, `malloc`, …) already emit `__cc_*` stubs that `x86sim.m`
emulates. The `mx*` API extends exactly this pattern.

## 3. Design decisions (stated up front)

- **A C double occupies one 64-bit word** in both tracks' memory, stored as
  its IEEE-754 **bit pattern** (MATLAB `typecast(double, 'int64')` on the
  interpreter side; `movq`/`movsd` on the compiler side). No separate float
  storage, no `float` keyword initially (a `float` is a `double` with
  rounding on store — out of scope for M1).
- **Class-id constants match real `mex.h`** (`mxDOUBLE_CLASS=6`,
  `mxINT32_CLASS=12`, `mxUINT32_CLASS=13`, `mxCHAR_CLASS=4`,
  `mxLOGICAL_CLASS=3`; note `mxSINGLE_CLASS=7`) so real-world MEX
  sources compile unchanged against the project's `mx.h`.
- **The `mxArray` layout is this project's own documented ABI** (it only
  needs to be *self-consistent* across the three tracks and the MATLAB
  host's loader; see §5).
- **`double` promotion**: binary `op` with any double operand promotes to
  double (C usual arithmetic conversions); casts `(double)x` / `(int)d`
  truncate toward zero (C99).
- **Math intrinsics** (`sin cos sqrt exp log fabs floor ceil fmod pow`)
  ship as libshims — real MEX code uses them, and they are trivial to
  emulate in MATLAB.

## 4. Phase A — `double` support in `xc.m` (interpreter track)

1. **Lexer**: accept a decimal point and exponent (`1.5`, `1e-3`, `.5`,
   `2.`); keep a second literal value `token_dval` (double) alongside
   `token_val`; a `Num` token with a fractional part or exponent yields the
   `DOUBLE` type at parse time.
2. **Type system**: add `DOUBLE = 3` to `CHAR/INT/PTR`; `expr_type`
   propagation with promotion rules; casts `(double)` / `(int)`.
3. **Opcodes** (new, mirroring the existing 38):
   - `LDD` / `SDD` — load/store an 8-byte double word (bit pattern),
   - `ADDD SUBD MULD DIVD` — double arithmetic on word bit patterns,
   - `CMPD` — double compare feeding the same branch opcodes (or a
     `double mode` flag on the existing `EQ..GE`),
   - `IMMD` — push a double bit-pattern literal,
   - `CVTID` (int→double) / `CVTDI` (double→int, truncating) for casts.
4. **Memory**: words already hold 64-bit patterns; `word_load`/`word_store`
   just gain a double interpretation (`typecast`), so arrays, structs and
   globals get doubles for free once the emitter/loader type is tracked.
5. **`printf`**: extend `sys_prtf` with `%f %e %g %a` (format via MATLAB
   `sprintf` with the value recovered from the bit pattern); `%d/%u/%x`
   unchanged.
6. **Math syscalls**: `sys_sqrt sin cos exp log fabs floor ceil fmod pow`
   (one syscall id each; values are doubles in the word).
7. **Verification**: a `double` corpus group in `run_tests.m`; each program
   cross-checked against gcc (exit code + stdout), same gate style as the
   existing groups.

## 5. Phase B — `double` support in `cc_int.m` + `x86sim.m` (SSE)

**cc_int.m** (emitter):
1. `double` keyword in `parse_basetype`; element size 8; alignment 8 in
   struct layout (`ssize_of`, member offsets).
2. **Literals**: `.rodata` double constants (`.quad <bit pattern>`) with
   `movsd` loads, or immediates via `movabsq $bitpattern`.
3. **SSE instruction subset** (Win64, AT&T):
   - `movsd` (mem↔xmm, xmm↔xmm) — loads/stores/copies,
   - `addsd subsd mulsd divsd` — arithmetic,
   - `xorpd %xmmN, %xmmN` — zero,
   - `cvtsi2sdq` (int→double), `cvttsd2siq` (double→int, truncating),
   - `ucomisd` + `seta/setb/sete/setne/setae/setbe` for comparisons
     (the existing `setcc` machinery extends naturally).
4. **ABI**: first 2 double args in `%xmm0/%xmm1` (subset), double return in
   `%xmm0`; callee-saved `%xmm6-%xmm15` untouched; stack alignment for
   spills. Struct-by-value with doubles uses the existing chunked-copy
   path (8-byte chunks already).
5. **`printf %f` shim**: `__cc_printf_*` reads the double args from xmm
   registers/stack per the Win64 convention and forwards the converted
   value to the existing shim.
6. **Math shims**: `__cc_sin_1`, `__cc_sqrt_1`, … one per intrinsic, same
   mechanism as `printf`/`malloc`.

**x86sim.m**:
7. 16 × 128-bit `%xmm0-%xmm15` registers (each a `[lo, hi]` double pair or
   byte array).
8. New opcode-table entries: `movsd addsd subsd mulsd divsd xorpd
   cvtsi2sdq cvttsd2siq ucomisd` with flag semantics (`ucomisd` sets
   ZF/PF/CF from the comparison; unordered NaN → PF).
9. Shim emulation for `__cc_sin_*`, `__cc_printf_*` (double args) using
   MATLAB `sin`, `sprintf`, etc.
10. **Cross-track parity**: double programs must agree between `xc.m` and
    `cc_int.m`+`x86sim.m` (exit codes and stdout), gcc-gated.

## 6. Phase C — the `mxArray` ABI and the `mx*` API

**Layout** (this project's documented ABI; 64-bit, 8-aligned):

```
offset 0:  magic          (0x4D584152 'MXAR', sanity check)
offset 8:  class_id       (mxDOUBLE_CLASS=6, mxINT32_CLASS=12, ...)
offset 16: flags          (logical / complex / global bits)
offset 24: rank           (ndims, 1..3 initially)
offset 32: dims[3]        (inline, 8 bytes each)
offset 56: pr             (data pointer: double* for DOUBLE, int32* for INT32, ...)
offset 64: pi             (imag data pointer, 0 if not complex)
offset 72: refcount       (owned by the host, not the C side)
total: 80 bytes
```

**`mx.h`** (project-owned, mirroring the real function signatures):
`mxCreateDoubleMatrix`, `mxCreateDoubleScalar`, `mxCreateNumericMatrix`,
`mxGetPr`, `mxGetPi`, `mxGetData`, `mxGetM`, `mxGetN`, `mxGetScalar`,
`mxGetNumberOfElements`, `mxGetDimensions`, `mxGetClassID`, `mxGetElementSize`,
`mxIsDouble`, `mxIsComplex`, `mxSetData`, `mxSetDimensions`, `mxDestroyArray`,
`mxAssert`, `mxGetString`, `mxCreateString`. Only DOUBLE/INT32/CHAR/LOGICAL
classes for M1.

**Two implementations, one contract**:
1. **`mx.c`** — C source, compilable by `cc_int.m` once Phase B lands; the
   same file is also compilable by real gcc for the reference track.
2. **MATLAB stubs** — one function per `mx*` entry that operates on a
   MATLAB struct mirroring the layout; registered so that:
   - `xc.m` resolves `mx*` calls as extern/syscall calls into the stubs,
   - `x86sim.m` emulates `__cc_mx*_<nargs>` shims by calling the stubs.

**mexFunction convention**: the runner constructs `prhs[]` (an array of
mxArray handles = addresses in the simulated heap), zeroes `plhs[]`, calls
the entry, then reads `plhs[0..nlhs-1]` back through `mx*` stubs.

## 7. Phase D — the mex runner, driver, and harness

- **`mex_run.m`** — the driver:
  - `mex_run('src.c', x1, x2)` interprets the source with `xc.m`
    (mx stubs) and returns the output arrays as MATLAB arrays;
  - `mex_run('src.c', x1, x2, 'compile')` compiles with `cc_int.m` →
    `.s`, simulates with `x86sim.m` (mx shims) and returns the outputs;
  - `mex_run(..., 'gcc')` writes a `main.c` harness (builds prhs from the
    MATLAB inputs via `mx.c`, calls `mexFunction`, dumps plhs to stdout),
    compiles with real gcc, runs it, parses the dump — the reference track.
- **Harness group (run_tests.m group 11)**: MEX sources
  - `mxdouble.c` — `plhs[0] = mxCreateDoubleMatrix(m,n); copy prhs → pr`
    (element order, dims),
  - `mxscalar.c` — `mxGetScalar` round-trip,
  - `mxshape.c` — `mxGetM/N/NumberOfElements` checks,
  - `mxint.c` — INT32 data movement via `mxCreateNumericMatrix`,
  - `mxchar.c` — `mxCreateString`/`mxGetString`,
  - `mxmath.c` — `sin/sqrt` over a prhs double vector.
  Each runs through all three tracks; the harness asserts identical
  dumps (values, dims, class ids) — the existing cross-track parity
  methodology applied to MEX.
- **Deliverable**: `mex_run` gives a MATLAB host (e.g. the MATLAB-clone
  interpreter with future native MEX loading) a compiler-independent
  oracle: the same `.c` produces the same outputs in all three tracks, so
  the host's own loader/mx mapping can be validated against it.

## 8. Milestones and effort

| Milestone | Content | Est. |
|---|---|---|
| M1 (Phase A) | `double` in xc.m: lexer, type, opcodes, casts, `%f`, math syscalls, double corpus vs gcc | 300–500 lines |
| M2 (Phase B) | SSE in cc_int.m + xmm in x86sim.m, printf/math double shims, parity | 400–600 lines |
| M3 (Phase C) | mxArray ABI, `mx.h`/`mx.c`, MATLAB stubs, mexFunction convention | 300–400 lines |
| M4 (Phase D) | `mex_run` driver, group 11 harness, gcc reference track | 200–300 lines |

Each milestone keeps `run_tests.m` green (the existing 669 checks stay
passing; new groups append).

## 9. Risks / open questions

- **SSE correctness** — the simulator's `ucomisd` flag semantics and
  NaN/unordered handling are the most error-prone part; the gcc parity
  group is the safety net. Keep the instruction subset minimal.
- **`%f` formatting parity** — MATLAB `sprintf` vs glibc `printf` differ in
  rounding/width edge cases; the parity tests pin the cases that matter
  and document the rest.
- **mxArray layout is a contract** — the MATLAB host's native loader must
  adopt this layout (or a mapping to it) for the oracle to be useful;
  the layout doc should live in this repo and be referenced by the host.
- **`float` and `long double`** — out of scope for M1; `float` = `double`
  with store-rounding is a follow-up.
- **Complex mxArrays** (`mxGetPi`) — layout reserves `pi`; complex support
  is a follow-up.
- **Performance** — `x86sim` runs at MATLAB speed; `mex_run` is a
  validation tool, not a runtime.

## 10. GCC reference track — DONE (2026-08-25)

`mex_run(..., 'gcc')` is implemented:

- **`src/mx_ref.c`** — a standalone native mx/mex runtime implementing the
  documented mxArray ABI (exact offsets, extended struct/cell/sparse/cells
  area) plus the corpus's mx*/mex* surface (~80 entries incl. the protocol
  helpers).  Compiles with real gcc; the mex source's preprocessor lines
  are stripped cc_int-style so both tracks compile BYTE-IDENTICAL code
  text, only the toolchain differs.
- **`src/mex_run_gcc.m`** — the driver: assembles [std includes + decls +
  mx_ref.c + stripped source + harness main], caches the build by
  comparing the assembly, compiles with gcc (`-O2 -w -std=c11`; locates
  gcc via MW_MINGW64_LOC → msys64 ucrt64 → PATH), runs the exe with the
  inputs (text protocol file: `N <nrhs>` + one spec per input:
  D/Z/C/L/I/CE/ST/SP), and parses the plhs dump back into MATLAB arrays.
- **`tests/run_mex_run_gcc.sh`** — the A/B gate: `mex_run(src, ins...)`
  (x86sim track) vs `mex_run(src, ins..., 'gcc')` must be `isequal` on
  every corpus pair.  **18/18 pass** across the group-11 sources and the
  main repo's B+ parity corpus (mxcell build+get, mxstruct build+get,
  mxsparse build+get, mxerror 'id', mxprint, mxpersist get+lock, yprime,
  matrixDivideComplex).  mexcallmatlab.c is excluded: mexCallMATLAB /
  mexEvalString / mexGetVariable need a MATLAB host (mx_ref.c raises a
  clear error for them).

**Clone quirks hit along the way** (all worked around):
- `v(:).'` on a char returns a **double** in the clone — dropped the
  defensive transpose in the serializer.
- `['a' 10 'b']` (bare `10` between char literals) yields a **double**
  (no char promotion); wrap the assembly in `char(...)` before writing.
- `fprintf(2, ...)` is the only stderr form (bare `stderr` is undefined).
- The exe must `freopen` the input/output files onto stdin/stdout (the
  driver passes them as argv; mexPrintf routes to stderr so it cannot
  corrupt the plhs dump protocol).
- mxIsNaN/mxIsInf/mxIsFinite are VALUE-based (real mex.h macros), not
  mxArray-based.
- GCC 14+ treats implicit declarations as errors: mx_ref.c carries full
  forward declarations.
