# Writing-a-C-Compiler-in-Matlab

Building compilers/interpreters in MATLAB, following two classic tutorials:

1. **Assembly track** (`cc_int.m`) — Norasandler's [Writing a C
   Compiler](https://norasandler.com/2017/11/29/Write-a-Compiler.html):
   compiles C to x86-64 assembly. Part 1: `return <int>;`. Part 2: unary
   operators (`-`, `~`, `!`, unary `+`, nested). Part 3: bitwise binary
   operators (`|`, `&`, `^`, `<<`, `>>`) with C precedence. Part 4:
   logical operators (`||`, `&&`) with short-circuit jumps and 0/1
   results. Part 5: comparisons (`==`, `!=`, `<`, `>`, `<=`, `>=`, signed or
   unsigned by the operands' common type) with 0/1 results via setcc. Part 6: arithmetic (`+`, `-`, `*`, `/`, `%`)
   with full C precedence, parenthesised expressions, `cqto`/`idivq`
   division (truncation toward zero, the remainder taking the dividend's sign,
   and the quotient narrowed back to its C width).
   Part 7: statements and variables — `int x;` / `int x = 5;` (comma
   lists), a local stack frame, expression statements, right-associative
   address-based assignment (`y = x = 5`), locals as primaries. Part 8:
   control flow — `if`/`else`, `while`, blocks, and `return` anywhere
   (jumps to the epilogue). Part 9: functions — multiple `int f(int a,
   int b)` definitions, calls (args pushed left-to-right, `call`, `addq`
   cleanup), per-function frames, recursion and forward references, and an
   arg-count check. Part 10: `char` variables/params/globals (byte
   `movzbl`/`movb`, char literals), globals (`.comm`/`.data`,
   rip-relative), and compound assignment (`+=`, `-=`, `*=`, `/=`, `%=`,
   `<<=`, `>>=`, `&=`, `|=`, `^=`). Part 11: pointers and arrays (`int *p`,
   `int a[10]`, `&`/`*`, `p[i]`, scaled pointer arithmetic), string
   literals, `++`/`--`, `?:`, `for`/`do-while`, `break`/`continue`, and
   `//`/`/* */` comments. Values live in 64-bit registers but keep their C
   width — int 32, long 4, long long 8 — so a store narrows and addresses still
   round-trip. Part 12: structs — `struct Tag { … };`
   definitions, struct variables/arrays/pointers (`.`, `->`, nested),
   element-scaled pointer arithmetic; params/returns are by-value (a
   hidden return slot at `16+8*nparams(%rbp)`, chunked 8-byte copies).
   Part 13: `switch` (case dispatch in %r10, break targets the switch end),
   `sizeof` (types and expressions), array initializers (`{1,2,3}` and
   `"str"`, local + global), `typedef`, `enum` constants, and
   multi-dimension arrays (`int a[2][3]` with per-level strides).
   Part 14: nested-brace multi-dim initializers (row-major group
   alignment), function pointers (bare function names give addresses,
   calls through `call *%rax`, `int (*fp)(int,int)` declarations),
   `goto`/labels (forward jumps backpatched), by-value struct
   params/returns. Part 15: `void` functions (and `(void)` params, bare
   `return;`), casts (`(int)x`, `(char*)p`, `(char)300` → 44), the comma
   operator, global function pointers, global struct initializers
   (`struct P gp = {5,6};`). Part 16: struct-returning function pointers
   (the return type is encoded in the fptr type), local struct definitions
   (incl. the compound `struct Q { … } q;` form), local `enum`s (values may
   be constant expressions), and string→char[] assignment (`s = "hi"`
   copies bounded by the array size). Part 17: a runtime library — calls to
   `printf`/`malloc`/`memset`/`memcmp`/`exit`/`open`/`read`/`close` emit
   Win64-ABI adapter shims in the generated assembly, so compiled programs
   can print, allocate, and read files.
2. **Interpreter track** (`xc.m`) — lotabout's
   [write-a-C-interpreter](https://github.com/lotabout/write-a-C-interpreter):
   a C interpreter with a custom VM, ported to MATLAB — complete: lexer,
   recursive-descent parser, 38-opcode stack VM, syscalls. Current status:
   [docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md).

Not from either tutorial, and not required by them: an **assembler**
(`src/ma_asm.m`) that turns the compiler's own text output into bytes, checked
byte-for-byte against a reference assembler on the whole corpus. See
[The assembler](#assembler-ma_asmm) below.

## Layout

```
src/
  cc_int.m              assembly compiler (C → x86-64 .s)
  peephole_pass.m       post-codegen optimizer (dead code, constant
                        folding, address modes, stack traffic)
  xc.m                  C interpreter (lexer → parser → VM → syscalls)
  ma_asm.m              assembler (.s → bytes); see "The assembler" below
  x86sim.m              gcc-free x86-64 simulator for the .s output
  c_unescape.m          C escape-sequence decoder (shared by both lexers)
  mx_preamble.m         MatlabEngine (MEX) preamble for the double track
  mex_run.m             run MEX sources against real MATLAB
  mex_run_gcc.m         the same through gcc, for comparison
  mx_ref.c              reference MEX source
LICENSE, README.md

tests/
  run_tests.m         test harness: probe gate, VM, lexer, program corpus,
                      syscall/acceptance, cc_int/gcc, x86sim, cross-track
                      parity, instruction-count regression, peephole-pass
                      fixtures, and the assembler sections. Current counts:
                      docs/PROJECT_STATUS.md (a number here goes stale, and
                      has)
  asm_gate.m          assembles every corpus program and compares the
                      bytes with a reference assembler
  asm_errors.m        the inputs the assembler must refuse, each asserted
                      on the message
  env.sh              resolves the runtime and the paths; sourced, not run
  run_all.sh          the suite plus the MEX/double gates, one exit status
  probe_*.m           the primitive/literal/portability probes
  programs/           test C programs
    return_2.c        return 2; (part 1 of the Norasandler series)
    cc2_*.c–cc18_*.c  the tutorial's parts 2-18, one program per feature
    cc19_*.c–cc60_*.c extensions, dialect guards and regression programs
                      (gcc-gated in the suite)
    cc_bad_*.c        inputs a compiler must REFUSE, asserted on the message
    dreg_*, pp_*, mx_*  doubles, preprocessor and MEX cases
    hello.c           fibonacci demo — xc.m acceptance program
docs/
  PROJECT_STATUS.md                       current project status
  PORTABILITY.md                          the runtime differences that cost real bugs
  PLAN_assembler.md                       the assembler's plan and its measured record
  2026-08-16-reference-cross-check.md     reference xc.c parity verification
  2026-08-16-compiler-optimization-plan.md optimizer phases A–F + results
  2026-09-02-over-engineering-audit.md    over-engineering audit (ponytail-audit)
  2026-09-06-correctness-review-*.md      correctness reviews
  2026-09-07-x86sim-peephole-divergences.md  simulator vs peephole divergences
  2026-08-10-matlab-clone-bug-report.md   bugs found in the MATLAB clone (internal, gitignored)
```

## Usage

The examples below write the runtime as `"%MATLAB%"` (cmd) or `"$MATLAB"` (bash) — the
variable described under Requirements. There is no launcher script in this repository, so
that variable is how you name the runtime.

The compiler (`src/cc_int.m`) translates C to x86-64 assembly; you then
assemble/link with gcc and run, **or** execute the assembly with the
built-in gcc-free simulator (`src/x86sim.m`):

```
%MATLAB% -batch "addpath('src'); cc_int('prog.c','prog.s');"
%MATLAB% -batch "addpath('src'); rc = x86sim('prog.s')"   # no gcc

gcc prog.s -o prog.exe
./prog.exe            (bash)  /  prog.exe, then echo %errorlevel% (cmd)
```

**Requirements:** a MATLAB-compatible runtime and MSYS2 gcc (the
emitted assembly is COFF — it needs a Windows binutils). The suite runs on
any MATLAB-compatible runtime: set `MATLAB=<path to matlab.exe>`, which
`tests/env.sh` honours. If it is not set, `env.sh` falls back to the runtime
this project is developed on, which may not be installed on your machine —
export `MATLAB` rather than relying on the fallback. The `addpath('src')` is
required in `-batch` mode; in cmd the exit code is `%errorlevel%`.

**What it compiles:** the full Norasandler series (parts 1–17) — expressions
with C precedence, `if`/`while`/`for`/`do`/`switch`, functions (recursion,
forward references), `char`/`int`/pointers/arrays (multi-dim), structs by
value (params, returns, assignment), function pointers (incl.
struct-returning), `goto`/labels, `void`, casts, the comma operator,
`sizeof`, `typedef`, `enum`, array/struct initializers, string→`char[]` —
plus a runtime library: `printf` (full CRT formats), `malloc`, `memset`,
`memcmp`, `exit`, and `open`/`read`/`close` — and pointer-returning
function pointers (`int *(*fp)(int *)`), C99 compound literals
(`(struct P){…}`, `(int[]){…}`), `unsigned` types (unsigned division,
comparisons, and `>>`), hexadecimal and octal integer literals, and the
narrow fixed-width types (`short`/`word`/`long`), C escape sequences, and
integer constant suffixes (`5u`, `0xFFu`, `10L`).

For example, recursion + `printf`:

```c
int fib(int n) { if (n <= 1) { return 1; } return fib(n-1) + fib(n-2); }
int main() { int i; i = 0;
    while (i <= 10) { printf("fib(%2d) = %d\n", i, fib(i)); i = i + 1; }
    return 0; }
```

compiles to an exe that prints the fibonacci table 0..10 and exits 0. The
emitted assembly is then optimized by `peephole_pass.m` (a post-codegen
pass: dead-code removal, immediate/constant folding, address-mode
simplification, and stack-traffic reduction), so `cc_int`'s straightforward
codegen — every local load as `leaq` + `movq (%rax)`, every binary op
spilling its left operand — comes out lean. And structs + function
pointers + `malloc`:

```c
struct Point make(int a, int b) { struct Point p; p.x = a; p.y = b; return p; }
int add(int a, int b) { return a + b; }
int main() {
    struct Point p; int (*fp)(int, int); char *buf;
    p = make(3, 4); fp = add; buf = malloc(16);
    buf[0] = 'A'; buf[1] = 0;
    printf("p=(%d,%d) fp=%d %s\n", p.x, p.y, fp(10, 5), buf);
    return 0; }
```

→ `p=(3,4) fp=15 A`. Exit codes are the program's `return` value (or
`exit(n)`), truncated to the low 8 bits.

`tests/programs/cc2_*.c`–`cc18_*.c` are self-contained examples of each
tutorial feature, and `cc19_*.c`–`cc60_*.c` extend and guard them; `cc17_shim.c` shows `malloc`/`memset`/`memcmp`/`exit` together,
and `cc18_*.c` covers pointer-returning fptrs, compound literals, and
`unsigned`; `cc19_hex.c`–`cc20_litforms.c` cover the literal bases and
`cc21_width.c` the narrow widths. The
full suite (both tracks, cross-track parity,
stdout parity, instruction-count regression, optimizer unit fixtures, and
the static globals audit):

```
"$MATLAB" tests/run_tests.m
```

The dialect is complete against its documented scope (the former gaps —
pointer-returning function pointers, compound literals, `unsigned` — were
implemented in the cc18 round, and hex and octal literals in cc19/cc20).
Remaining conventions:
`main` must end with a top-level `return`, and `open()` paths are relative
to the working directory.

## Running

MATLAB code runs on a MATLAB-compatible runtime, and which one matters, because this
project's results are runtime-specific:

| Runtime | Role |
|---|---|
| **real MATLAB** (R2024b) | the authority when runtimes disagree — and they have |
| **the development runtime** — any MATLAB-compatible CLI; pass it as `$MATLAB` | where this project is developed, and where every check passes |
| **the C clone** — `MATLAB_in_C/release/` | the oracle for cross-checks, not a runtime the suite runs on |

`tests/env.sh` resolves it (`$MATLAB`, else the development runtime, else `matlab` on
PATH) and refuses a runtime that cannot run the harness. The suite is green on all three,
including the assembler sections, as of the 857-check authority run recorded in
`docs/PROJECT_STATUS.md`.

**Policy: a tag requires a real-MATLAB run.** Both tags so far were cut without one, and
the two runs that did happen found the three defects no clone could show. A release that
has not been through R2024b is a claim, not a verification.

### Assembly track (cc_int.m)

Windows cmd:

```
%MATLAB% -batch "addpath('src'); cc_int('tests/programs/cc2_nested.c','cc2_nested.s')"
gcc cc2_nested.s -o cc2_nested
.\cc2_nested.exe
echo %errorlevel%
```

(`addpath('src')` is needed in `-batch` mode: the clone does not put the working
directory on the MATLAB path implicitly — see the bug report. In cmd, the exit
code is `%errorlevel%` — bash's `$?` does not work there.)

Compiled programs may call the runtime library (`printf`, `malloc`, `memset`,
`memcmp`, `exit`, `open`/`read`/`close`) — the compiler emits a Win64-ABI
adapter shim per `{function, arg-count}` used (e.g. `__cc_printf_3`) that
re-packs the compiler's stack-arg convention into RCX/RDX/R8/R9 and calls the
CRT symbol, so programs can print and allocate. `hello.c` compiles through
`cc_int` and prints the same fibonacci table as the interpreter track.

Expected exit code: `1` (the value of `return -~!5;` — `!5` = 0, `~0` = -1,
`-(-1)` = 1). The emitted assembly uses COFF directives
(`.def main; .scl 2; .type 32; .endef`) instead of the tutorial's ELF
`.type main, @function` — the `@` form is rejected by MSYS2 binutils on
Windows. Exit codes are the low 8 bits of the returned value (214 for
`return -42;`, 213 for `return ~42;`, 255 for `return ~0;`). Verified
end-to-end: clone → `cc_int` → `gcc` (MSYS2 ucrt64 15.2.0) → exit code; the
suite's gcc-gated group compiles and runs every `cc2_*.c` program.

### Assembler (ma_asm.m)

`cc_int.m` emits text; `ma_asm.m` turns that text into bytes. The seam is deliberately
one function — a `.s` string in, an image out — so the assembler can be judged by
comparing bytes and nothing else:

```
%MATLAB% -batch "addpath('src'); img = ma_asm(fileread('prog.s'));"
```

It covers what this compiler emits: 61 mnemonics, the directives, labels, branches and
relocations, `.string`/`.quad` data, and rip-relative addresses. It does **not**
link, and it does not produce an object file — those need a format and a symbol table,
and neither buys anything a byte comparison does not already check.

**Verification: 338 of 338 corpus programs byte-identical to a reference assembler
(`as`), `.text` for `.text`, on two independent runtimes.** `CC_SECTIONS=asm` runs it as
one check, and `tests/asm_errors.m` asserts the ten inputs it must refuse — an unknown
mnemonic, an unresolved target, a shift by a register that is not `%cl`, an immediate
wider than 64 bits, and so on — each on the message, because these are the cases where
being wrong would be silent.

The first real-MATLAB run of the assembler disagreed with both clones - it refused 30
programs with 字段名称 ".byte" 无效, a `struct('.byte', 1, ...)` table the clones accept and
MATLAB does not - which is why the suite now checks that shape statically instead of trusting
a green run on a lenient runtime.

### Optimizer (peephole_pass.m)

`cc_int` emits straightforward assembly; `peephole_pass` rewrites it after
codegen (to a fixed point) into something much tighter. The rules
(`docs/2026-08-16-compiler-optimization-plan.md`, phases A–F):

- **dead code** — `jmp .L` straight to its own next label (every function's
  final `return` jumps to its epilogue), and unreachable instructions after
  any unconditional jump;
- **constant folding** — `movq $N, %rax; imulq $M, %rax` → `movq $N*M, %rax`
  (constant array indices), and the `cmpq; setcc; movzbl; cmpq $0; jcc`
  normalize-then-branch chain → a single `jcc` on the original compare;
- **address modes** — `leaq K(%rbp), %rax; movq (%rax), %rax` →
  `movq K(%rbp), %rax`, `movq $N, %rax; movq %rax, mem` → `movq $N, mem`,
  and `leaq K(%rbp), %rax; addq $N, %rax` → `leaq K+N(%rbp), %rax`;
- **stack traffic** — the binary-op spill `pushq %rax; <right>;
  movq %rax, %rbx; popq %rax; op %rbx, %rax` → `movq <right>, %rbx;
  op %rbx, %rax` (the left survives in rax across a push), with the
  div/mod (`cqto; idivq %rbx`) and shift (`movq %rax, %rcx; shlq %cl,
  %rax`) tails; and the store-LHS address rides in `%r8` instead of the
  stack (`movq %rax, %r8; <rhs>; movq %rax, (%r8)`) when the rhs makes no
  call.

Measured on the compiler corpus: **8,697 → 6,004 emitted instructions
(−31%)**, `pushq`/`popq` **2,391 → 571 (−76%)**, hello.c **106 → 72** —
with the suite green at every step (exit codes through gcc AND the
gcc-free x86sim must agree). The suite's instruction-count regression
ratchets the ceilings down per phase (and up when the corpus grows), and
the `ppunit` fixtures keep every individual fold rule tested in
isolation.

### Interpreter track (xc.m)

```
%MATLAB% -batch "addpath('src'); xc('tests/programs/hello.c')"
%MATLAB% -batch "addpath('src'); xc('-s', 'tests/programs/hello.c')"   # source + instruction dump
%MATLAB% -batch "addpath('src'); xc('-d', 'tests/programs/hello.c')"   # execution trace
```

`hello.c` prints the fibonacci table 0..10 and exits 0; the output is
byte-identical to the reference C build (verified in the test suite).

Post-parity additions beyond the reference dialect (all in the suite):
`/* */` block comments (multi-line, line-counted), `%s` in printf (width/
precision preserved; length modifiers like `%ls`/`%ld`/`%hd` are normalized
away), array declarations (`int a[10];` — global and local, indexed via
`[]`, decays to a pointer when passed), multi-dimension arrays
(`int a[2][3];` — global and local, row-major `a[i][j]`, rows decay to
pointers), constant initializers (`int x = 5;`, `char c = 'A';`,
`char *s = "abc";`), non-constant local initializers (any expression —
`int x = g + 1;` or `int x = f();` — emitted inline after ENT), array
initializers (`int a[3] = {1,2,3};` — global and local; multi-dim nested
braces `{{1,2,3},{4,5,6}}` with C 6.7.9 brace elision; char arrays also via
`char s[4] = "abc";`; shorter lists are C zero-filled, too-long lists error),
non-constant global initializers (`int h = g + 2;` — a startup prologue runs
them before main), `void` functions and `(void)` parameter lists, array
parameters (`int f(int a[3])` decays to a pointer), `sizeof` on array names
and expressions (incl. multi-dim rows: `sizeof(a[0])` = 24 for `int a[2][3]`),
printf `%*` dynamic width/precision, `%n` (writes the running count) and `%p`
(hex pointer), pointer-to-(sub)array types via `&` (`(&a[0])[1]` indexes
rows; `&a` is a pointer to the whole array), and multi-read file semantics
(each `read` advances a per-fd position). String literals are NUL-terminated
in memory (the reference relies on zeroed pages — consecutive literals would
otherwise bleed into each other). The dialect is feature-complete against its
documented scope; remaining C features (structs, unions, `switch`,
`for`/`do-while`, …) are outside both the port and the reference dialect.

Tests (the counts live in PROJECT_STATUS.md; probe gate, VM selftest, lexer selftest, the program
corpus whose exit codes/outputs are cross-verified against the reference
build, a gcc-gated group that compiles and runs the assembly-track
programs, a cross-track parity group that runs the shared corpus through
BOTH the interpreter and the compiler and asserts they agree, an
instruction-count regression, a static globals audit, and the optimizer's
per-rule unit fixtures):

```
"$MATLAB" tests/run_tests.m
```

The whole verification — the suite plus the four MEX/double gates
(`run_double_regression`, `run_mx_smoke`, `run_mex_run_smoke`,
`run_mex_run_gcc`, the last an oracle diffing the compile track against
`mex_run(..., 'gcc')`) — is one command:

```
bash tests/run_all.sh
```

It resolves the runtime from `$MATLAB`, else the development runtime, else `matlab` on PATH,
derives the repo path from its own location, and exits non-zero if any part fails —
distinguishing "some checks failed" from "the run was cut short", because a host that
kills the suite leaves no summary line and used to read as a failure.

A MATLAB-compatible CLI runs this code far slower than the C clone does, so the suite is
normally run in sections or program slices: `CC_SECTIONS` (including `asm`, the assembler
gate), `CC_CORPUS`, `CC_OSTESTS`.
`docs/2026-09-06-rust-engine-compat.md` records the compatibility work, including the
engine defects found from this project and since fixed.

Or in `-batch` mode:

```
%MATLAB% -batch "run('tests/run_tests.m');"
```

## Notes

- Licensed under the **GNU General Public License, version 2** (see
  `LICENSE`). `xc.m` is a derivative port of `xc.c` (GPL2,
  lotabout/write-a-C-interpreter, itself derived from c4) and carries a GPL
  notice header; `tests/programs/hello.c` is copied from the same repo.
- Reference cross-check: the interpreter's expected exit codes and `hello.c`
  stdout are verified against the reference `xc.c` build, compiled ad hoc
  with `gcc xc.c -o xc_ref.exe` from the
  [lotabout/write-a-C-interpreter](https://github.com/lotabout/write-a-C-interpreter)
  repository (gcc 15.2.0 at `C:\msys64\ucrt64\bin\gcc.exe`). Verified
  2026-08-16: `hello.c` stdout byte-identical (221 bytes) and `-s` dumps
  structurally identical — only the absolute-address operands differ, and
  those vary between builds of the reference itself (see
  `docs/2026-08-16-reference-cross-check.md`).
- Known bugs in the MATLAB clone (v1.2.37, fixed across v1.2.38-v1.3.21) are
  tracked in an internal bug report (`docs/2026-08-10-matlab-clone-bug-report.md`,
  gitignored — not shipped with the repo). The port follows real MATLAB semantics and
  avoids the clone's remaining quirks defensively; the C clone is used as the **oracle**
  at `release/v1.3.86`, and the runtime this project is developed on is a
  MATLAB-compatible CLI rather than the clone.
