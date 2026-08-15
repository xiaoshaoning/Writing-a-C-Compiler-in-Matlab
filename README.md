# Writing-a-C-Compiler-in-Matlab

Building compilers/interpreters in MATLAB, following two classic tutorials:

1. **Assembly track** (`cc_int.m`) — Norasandler's [Writing a C
   Compiler](https://norasandler.com/2017/11/29/Write-a-Compiler.html):
   compiles C to x86-64 assembly. Part 1: `return <int>;`. Part 2: unary
   operators (`-`, `~`, `!`, unary `+`, nested). Part 3: bitwise binary
   operators (`|`, `&`, `^`, `<<`, `>>`) with C precedence and
   left-associativity.
2. **Interpreter track** (`xc.m`) — lotabout's
   [write-a-C-interpreter](https://github.com/lotabout/write-a-C-interpreter):
   a C interpreter with a custom VM, ported to MATLAB — complete: lexer,
   recursive-descent parser, 38-opcode stack VM, syscalls. Design and
   implementation plan: [docs/2026-08-10-xc-matlab-port-plan.md](docs/2026-08-10-xc-matlab-port-plan.md).

## Layout

```
cc_int.m              assembly compiler (return <unary>; → x86-64 .s)
xc.m                  C interpreter (lexer → parser → VM → syscalls)
tests/
  run_tests.m         test harness (168 checks: probe gate, VM, lexer,
                      program corpus, syscall/acceptance, cc_int/gcc)
  programs/           test C programs
    return_2.c        return 2; (part 1 of the Norasandler series)
    cc2_*.c / cc3_*.c  unary / bitwise-operator programs (parts 2-3,
                      gcc-gated in the suite)
    hello.c           fibonacci demo — xc.m acceptance program
docs/
  2026-08-10-xc-matlab-port-plan.md        implementation plan
  PROJECT_STATUS.md                        current project status
  2026-08-10-matlab-clone-bug-report.md    bugs found in the MATLAB clone (internal)
```

## Running

MATLAB code runs on the custom MATLAB clone:

```
D:\Projects\codes\MATLAB_in_c\release\v1.3.21\matlab.bat
```

### Assembly track (cc_int.m)

Windows cmd:

```
matlab.bat -batch "addpath('.'); cc_int('tests/programs/cc2_nested.c','cc2_nested.s')"
gcc cc2_nested.s -o cc2_nested
.\cc2_nested.exe
echo %errorlevel%
```

(`addpath('.')` is needed in `-batch` mode: the clone does not put the working
directory on the MATLAB path implicitly — see the bug report. In cmd, the exit
code is `%errorlevel%` — bash's `$?` does not work there.)

Expected exit code: `1` (the value of `return -~!5;` — `!5` = 0, `~0` = -1,
`-(-1)` = 1). The emitted assembly uses COFF directives
(`.def main; .scl 2; .type 32; .endef`) instead of the tutorial's ELF
`.type main, @function` — the `@` form is rejected by MSYS2 binutils on
Windows. Exit codes are the low 8 bits of the returned value (214 for
`return -42;`, 213 for `return ~42;`, 255 for `return ~0;`). Verified
end-to-end: clone → `cc_int` → `gcc` (MSYS2 ucrt64 15.2.0) → exit code; the
suite's gcc-gated group compiles and runs every `cc2_*.c` program.

### Interpreter track (xc.m)

```
matlab.bat -batch "xc('tests/programs/hello.c')"
matlab.bat -batch "xc('-s', 'tests/programs/hello.c')"   # source + instruction dump
matlab.bat -batch "xc('-d', 'tests/programs/hello.c')"   # execution trace
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

Tests (168 checks — probe gate, VM selftest, lexer selftest, the program
corpus whose exit codes/outputs are cross-verified against the reference
build, and a gcc-gated group that compiles and runs the assembly-track
programs):

```
matlab.bat tests/run_tests.m
```

Or in `-batch` mode (the clone does not resolve a script's local functions
when the script is run by name after `addpath`, so invoke the file with `run`):

```
matlab.bat -batch "run('tests/run_tests.m');"
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
  repository (gcc 15.2.0 at `C:\msys64\ucrt64\bin\gcc.exe`).
- Known bugs in the MATLAB clone (v1.2.37, fixed across v1.2.38-v1.3.21) are
  tracked in an internal bug report (`docs/2026-08-10-matlab-clone-bug-report.md`,
  gitignored — not shipped with the repo); the port targets v1.3.21, follows
  real MATLAB semantics, and avoids the remaining quirks defensively.
