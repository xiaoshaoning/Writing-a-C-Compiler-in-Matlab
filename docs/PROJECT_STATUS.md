# Project Status — 2026-08-10

## Summary

**Interpreter track (`xc.m`): complete.** A single-file MATLAB port of
lotabout's [write-a-C-interpreter](https://github.com/lotabout/write-a-C-interpreter)
(`xc.c`, itself derived from c4): lexer → recursive-descent parser with
on-the-fly codegen → 38-opcode stack VM → syscalls. All seven planned phases
are done, plus six post-parity features beyond the reference dialect.

**Compiler track (`cc_int.m`): feature-complete + a runtime library.**
Norasandler's [Writing a C Compiler](https://norasandler.com/2017/11/29/Write-a-Compiler.html)
series (parts 1–13) plus structs by value, function pointers (incl.
struct-returning), `goto`/labels, `void`, casts, the comma operator, global
struct initializers, local structs/enums, string→char[], and a runtime
library (`printf`/`malloc`/`memset`/`memcmp`/`exit`/`open`/`read`/`close`
via Win64-ABI shims) — so compiled programs print, allocate, and do file I/O.
`hello.c` compiles through `cc_int` and prints the same fibonacci table as
the interpreter.

**Cross-track parity harness (2026-08-15).** A suite group that runs the
shared corpus through BOTH tracks — `xc` (interpreter) and `cc_int`
(compiler) — and asserts `mod(interp_exit, 256) == compiler_exit` (the OS
truncates the exit code to the low byte). 187 programs are shared and agree
on exit codes, and 53 more agree on full stdout (47/47 of the matchable
`pp_*` corpus — the excluded ones are the intended-error tests and `%p`,
whose synthetic interpreter pointers can never match real addresses); the
interpreter-only programs are the documented dialect divergences (structs,
`switch`, `typedef`, `for`/`do`/`break`/`continue`, …). Two independent
implementations confirming each other on every suite run.

**Fix (part 6): `cdivmod` negative-divisor bug.** Cross-checking the
arithmetic corpus against the interpreter exposed a latent `xc.m` bug:
`mod(a,b)` has the *divisor's* sign, so `7 / -2` gave -4 (C: -3) and
`7 % -2` gave -1 (C: +1). Rewritten as `q = fix(a/b); r = a - q*b`
(truncation toward zero, remainder with the dividend's sign) — 4 new VM
selftest cases (now 30) and `pp_divmod.c` (exit 89) cover it.

**Compiler: four dialect gaps closed (2026-08-15).** `cc_int.m` now
supports nested-brace multi-dim initializers (row-major group alignment,
`{{1,2},{3}}` on `int[2][3]`), function pointers (bare function name →
address, calls through pointers with `call *%rax`, `int (*fp)(int)`
declarations), `goto`/labels (forward jumps backpatched per function), and
by-value struct params/returns (hidden return slot at `16+8*nparams(%rbp)`
pushed deepest by the caller, chunked 8-byte copies both ways, size-8
structs handled). Test corpus: `cc14_*` (12 programs). Also fixed: `si`
missing from `parse_statement`'s globals (the label-peek restore was a
no-op), a lost `bstride`/`isst` block in `parse_unary`, `estruc` not reset
by Num/Str literals, and forward function references (mutual recursion).

**Compiler: void, casts, comma, global function pointers, global struct
initializers (2026-08-15).** `cc_int.m` gained: `void` functions (and
`(void)` params, bare `return;`, empty bodies via a block-style body parse
for void functions), C casts `(int)x`/`(char*)p`/`(char)x` (the `(`-branch
peeks for a type keyword; `(char)` truncates with `movsbl`), the comma
operator (`parse_expr` is now `assignment (',' assignment)*`; parenthesised
and statement expressions use it too), global function pointers
(`int (*gfp)(int,int);`), `(*fp)(args)` calls (function pointers carry a
2002 type marker so `*fp` skips the load), and global struct initializers
(`struct P gp = {5,6};`, nested `{{…},…}`, char members, partial inits —
member declaration order is tracked in the struct def and the values are
laid out into bytes little-endian). Test corpus: `cc15_*` (20 programs).

**Compiler: struct-returning function pointers, local structs/enums,
string→char[] (2026-08-15).** `cc_int.m` gained: struct-returning function
pointers (`struct P (*fp)(int)` — the return type is encoded into the fptr
type as `2000 + rettype`, so a call through a struct-returning pointer
reserves the hidden slot and pops it correctly; char-returning pointers
work too), local struct definitions (including the compound
`struct Q { … } q;` form, file scope included, via a `register_struct`
that returns the stid), local `enum`s (statement-level dispatch), enum
values as constant expressions (`B = A + 2` — a compile-time evaluator),
and string→char[] assignment (`s = "hi"` copies the bytes bounded by the
array's size; `a[1] = "xy"` for rows; the array's total size is tracked
in `lvararrsz`/`gvararrsz`). Fixed: the call-through-pointer reload/cleanup
offsets scaled by the slot size (16-byte structs called `24(%rsp)` — a
garbage slot word — instead of `16+rsz`), indexed-row lvalues
(`lvalue_addr` accepts the `addq %rbx, %rax` tail; the row branch restores
`etype`), and `curarrsz` now tracks rows. Test corpus: `cc16_*` (14
programs).

**Compiler: runtime library shims (2026-08-15) — stdout, heap, and file I/O.**
`cc_int` emitted nothing but exit codes before; now calls to `printf`,
`malloc`, `memset`, `memcmp`, `exit`, `open`/`read`/`close` generate
Win64-ABI adapter shims (`__cc_<name>_<nargs>`) in the assembly that
re-pack our stack-arg convention into RCX/RDX/R8/R9 + the 32-byte shadow
space, 16-align via `andq $-16, %rsp`, zero AL for varargs, and call the
CRT symbol (`_open`/`_read`/`_close` for the file trio). hello.c now
compiles and prints the reference's fibonacci table; the suite gained a
cross-track OUTPUT-parity group (6 programs whose stdout must match through
both tracks, the interpreter's trailing `exit(N)` trace stripped) and the
cc17 corpus. Also: `#` preprocessor lines are skipped by the lexer, and the
harness retries gcc once for the documented transient flakes.

**x86sim: a gcc-free mini x86-64 simulator (2026-08-15).** `x86sim.m`
interprets the assembly emitted by `cc_int` directly — no assembler,
linker, or gcc. It parses the COFF-ish directives, lays out
`.comm`/`.data`/`.string` in a byte memory, executes the instruction stream
(registers, flags, stack, `call`/`ret`), emulates the CRT entry (the exit
code = `main`'s return value), and implements the runtime library the shims
forward to (`printf` with the corpus formats, `malloc`, `memset`, `memcmp`,
`exit`, `_open`/`_read`/`_close`). All 281 compiler-corpus programs produce
the same exit codes through the simulator as through gcc, and hello.c
prints the same fibonacci table; the suite gained a gcc-free corpus group.
Clone quirks worked around along the way: string literals matching internal
names (`sum`, `count`, `set`) are mangled when they cross local-function
boundaries (so all text is handled as double code vectors and compared with
`cv_eq`), and the emitted `r8..r15` indices were off by one.

**Optimization plan (2026-08-16).** A detailed phased plan for
generated-code quality (primary) and compiler clarity (secondary):
`docs/2026-08-16-compiler-optimization-plan.md`. Baseline: 8,689 corpus
instructions / 220,726 bytes with 2,391 push/pop (27.5% of all
instructions). Phases: measurement harness (permanent instruction-count
regression group) → peephole → address-mode simplification → constant
folding → structural stack-traffic reduction (a small register
allocator) → clarity refactor → x86sim extension. Every phase gates on
the 727-check suite staying green.

**x86sim stdout parity + compiler leftovers (2026-08-15).** The gcc-free
track now also asserts stdout: the 53 printing programs must produce the
same output through `x86sim` as through the interpreter (53 new checks).
The compiler gained the last three dialect gaps: pointer-returning
function pointers (`int *(*fp)(int *)` — and pointer-returning functions),
C99 compound literals (`(struct P){…}` allocated as a stack temp,
`(int[]){…}` incl. unsized, `(char[]){…}`, scalar `(int){…}`), and
`unsigned` types (64-bit; unsigned `divq`/`shrq` and the `setb`/`seta`/
`setbe`/`setae` comparison family; the simulator learned the same
instructions). Test corpus: `cc18_*` (5 programs).

**Compiler: parity completion (2026-08-15) — 47/47 of the matchable
interpreter corpus agrees through both tracks.** Three compiler gaps
closed: the emitted `.comm` used the byte size as the COFF alignment,
which mingw ld silently rejects for some values (32/40/48/56/96) — a
fixed alignment of 16 works for every size; `(void)` params
double-consumed the `)` (leaving `{` for the caller's expect); and the
CRT printf got the raw `%ls` (wide-string meaning) instead of the
interpreter's narrow-string convention — the compiler now normalises the
same length modifiers as xc.m. Plus non-constant global initializers
(`int h = g + 2;`, `int h = f();`) evaluate in main's startup prologue.
The output-parity group grew from 6 to 53 programs (hello, p6_*, and 47
of the pp_* corpus); the 4 excluded are the intended-error tests and
`%p` (synthetic interpreter pointers vs real addresses — inherently
unmatchable).

## Deliverables

| Phase | Scope | Commit |
|---|---|---|
| 0 | Scaffold, runtime probe gate, test harness | `0361566` |
| 1–2 | 38-op VM (`vm_eval`), lexer (`next`), keyword seeding | `d9bd61a` |
| 3 | Parser core: `program`, declarations, `expression`, `statement`, functions | `8584773` |
| 4 | Function corpus: recursion, multi-arg, char params, shadowing | `afa04c1` |
| 5 | Pointer/array/cast corpus: swap, walks, ptr-to-ptr, ptr diff, bitwise | `cd1902c` |
| 6–7 | All eight syscalls, hello.c acceptance, cleanup | `78cee00` |
| post-parity | Block comments, `%s` printf, arrays, initializers, `void`, multi-read | `52c0016` |

**Compiler track (`cc_int.m`)** — Norasandler parts 2–13 landed in
individual commits (`06f4ad8`…`aa85d46`); the post-tutorial feature rounds
and the runtime library are the changelog entries above:

| Round | Scope | Commit |
|---|---|---|
| cc14 | nested multi-dim inits, function pointers, goto/labels, by-value struct params/returns | `a482286` |
| cc15 | `void`, casts, comma, global function pointers, global struct inits | `199226f` |
| cc16 | struct-returning fptrs, local structs/enums, string→char[] | `840193b` |
| cc17 | runtime library shims (printf/malloc/memset/memcmp/exit/open/read/close) | `7813eb7` |
| cc18 | pointer-returning fptrs, compound literals, `unsigned` | *this round* |
| parity | cross-track exit-code parity (187) + output parity (53, 47/47 matchable `pp_*`) | `04da1b7` `57e2fae` |
| verify | reference cross-check + ENT dump fix | `f697b72` |

## Verification

- **Test suite**: `tests/run_tests.m` — **669/669** on the target runtime
  (146 interpreter checks + 287 gcc-gated assembly-track checks + 187
  cross-track parity checks + 53 cross-track output-parity checks + 1
  gcc-free simulator corpus group — `x86sim.m` runs all 281 compiler
  programs without gcc; the gcc group skips if gcc is absent).
  Groups: runtime-primitive gate (probe), 30-case VM selftest, 9-case lexer
  selftest, program corpus (p3–p6, pp), syscall/acceptance, `-s`/`-d` smoke.
- **Reference cross-check**: the reference `xc.c` built with gcc 15.2.0
  (`C:\msys64\ucrt64\bin\gcc.exe`). Every corpus program's exit code is
  identical to the reference; `-s` instruction dumps are byte-identical
  modulo absolute-address jump targets (the port uses slot indices — an
  inherent consequence of the two-space memory model); `hello.c` stdout is
  byte-exact (the fibonacci table + `exit(0)` with no trailing newline) and
  is asserted in the suite with its full expected output.
- **Regression**: the probe gate re-verifies the primitives the port depends
  on before every run, so a runtime behavior regression fails loudly.

## Post-parity features (beyond the reference)

- `/* */` block comments (multi-line, line-counted; unterminated → error)
- `%s` in printf (width/precision/truncation preserved)
- Array declarations: `int a[10];` global and local; `a[i]`, `&a`, passing
  to functions (decay-to-pointer) all work
- Multi-dimension arrays: `int a[2][3];` global and local, row-major
  `a[i][j]` with per-level byte strides; rows decay to pointers; flat
  initializers `{1,2,3,4,5,6}` work
- Array initializers: `int a[3] = {1,2,3};` global and local (braces form);
  char arrays also via `char s[4] = "abc";` string form; shorter lists are
  C zero-filled, too-long lists error; multi-dim nested braces
  (`{{1,2,3},{4,5,6}}`) with C 6.7.9 brace elision
- Non-constant global initializers: any expression (`int h = g + 2;`, `int h = f();`)
  — the expression is balanced-skipped at declaration, re-parsed into a
  startup prologue that runs before main (then jumps to main)
- Non-constant local initializers: any expression (`int x = g + 1;`, `int x = f();`)
  — the frame is emitted first (ENT with a backpatched size), initializers
  inline after it
- `void` functions and `(void)` parameter lists; array parameters decay to
  pointers (`int f(int a[3])`)
- `sizeof` on array names (total bytes, stored in the symbol table) and on
  expressions — array-valued operands report their byte size, so
  `sizeof(a[0])` on `int a[2][3]` is 24
- printf length modifiers normalized away (`%ls`/`%ld`/`%hd`/`%llu` → plain
  `%s`/`%d`/`%u`/`%d`); `%*` dynamic width/precision; `%n` writes the running
  count to its arg address; `%p` prints a lowercase-hex pointer; string
  literals NUL-terminated in mem (consecutive literals no longer bleed)
- Pointer-to-(sub)array via `&`: `(&a[0])[1]` indexes rows, `&a` is a pointer
  to the whole array (its strides carry the sub-array size)
- Constant initializers: `int x = 5;`, `char c = 'A';`, `char *s = "abc";`
- `void` functions: `void f() { return; }` (void variables rejected)
- Multi-read file semantics: repeated `read()` calls advance a per-fd
  position

## Known limitations (documented dialect gaps)

The interpreter port is feature-complete against its documented scope. C
features outside the scope of both the port and the reference dialect
(structs, unions, `switch`, `for`/`do-while` loops, preprocessor macros, …)
are unsupported. The compiler track (`cc_int.m`) supports all of those plus
structs, but still lacks: pointer-returning function pointers
(`int *(*fp)(int)` declarations), compound literals, and `unsigned` types;
calls through pointers always use the interpreter-style stack convention.

- The `-s` mnemonic column is padded manually to match the reference's
  `%8.4s` output (the runtime pads to width but not to string precision)

## Runtime notes

The port follows **real MATLAB semantics**: int64 arithmetic saturates at
INT64_MAX/MIN, integer division keeps its class with half-away-from-zero
rounding, bitwise ops preserve the sign bit. VM DIV/MOD keep C truncation
via `cdivmod` (exact double math, values < 2^53 — `word_store` asserts the
bound). The port targets the current runtime; historical behavior gaps and
their resolutions are tracked in the (internal, gitignored) runtime bug
report.

## Resolved items

1. **GPL2 adoption** — DONE (2026-08-15): `LICENSE` added (GNU GPL version 2,
   canonical FSF text); GPL notice headers on `xc.m`/`cc_int.m`; README
   attribution updated.
2. **Reference-build reproducibility** — DONE (2026-08-15): the ad hoc
   `gcc xc.c -o xc_ref.exe` cross-check command is documented in the README
   (verified 2026-08-16: hello.c stdout byte-identical, `-s` dumps
   identical modulo the absolute-address operands — see
   `docs/2026-08-16-reference-cross-check.md`).
   Notes.

## Running

```
D:\...\matlab.bat tests/run_tests.m          # full suite (669 checks)
D:\...\matlab.bat -batch "addpath('src'); xc('tests/programs/hello.c')"   # acceptance program
D:\...\matlab.bat -batch "addpath('src'); xc('-s', 'tests/programs/hello.c')"  # compile dump
D:\...\matlab.bat -batch "addpath('src'); xc('-d', 'tests/programs/hello.c')"  # trace
```

See `README.md` for both tracks and the layout.
