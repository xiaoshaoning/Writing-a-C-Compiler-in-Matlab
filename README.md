# Writing-a-C-Compiler-in-Matlab

Building compilers/interpreters in MATLAB, following two classic tutorials:

1. **Assembly track** (`cc_int.m`) — Norasandler's [Writing a C
   Compiler](https://norasandler.com/2017/11/29/Write-a-Compiler.html):
   compiles C to x86-64 assembly. Currently part 1: `return <int>;`.
2. **Interpreter track** (`xc.m`) — lotabout's
   [write-a-C-interpreter](https://github.com/lotabout/write-a-C-interpreter):
   a C interpreter with a custom VM, ported to MATLAB — complete: lexer,
   recursive-descent parser, 38-opcode stack VM, syscalls. Design and
   implementation plan: [docs/2026-08-10-xc-matlab-port-plan.md](docs/2026-08-10-xc-matlab-port-plan.md).

## Layout

```
cc_int.m              assembly compiler (return N; → x86-64 .s)
xc.m                  C interpreter (lexer → parser → VM → syscalls)
tests/
  run_tests.m         test harness (105 checks: probe gate, VM, lexer,
                      program corpus, syscall/acceptance)
  programs/           test C programs
    return_2.c        return 2; (part 1 of the Norasandler series)
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
matlab.bat -batch "addpath('.'); cc_int('tests/programs/return_2.c','return_2.s')"
gcc return_2.s -o return_2
.\return_2.exe
echo %errorlevel%
```

(`addpath('.')` is needed in `-batch` mode: the clone does not put the working
directory on the MATLAB path implicitly — see the bug report. In cmd, the exit
code is `%errorlevel%` — bash's `$?` does not work there.)

Expected exit code: `2` (the constant in `return 2;`). The emitted assembly
uses COFF directives (`.def main; .scl 2; .type 32; .endef`) instead of the
tutorial's ELF `.type main, @function` — the `@` form is rejected by MSYS2
binutils on Windows. Verified end-to-end: clone → `cc_int` → `gcc` (MSYS2
ucrt64 15.2.0) → exit 2.

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
precision preserved), array declarations (`int a[10];` — global and local,
indexed via `[]`, decays to a pointer when passed), constant initializers
(`int x = 5;`, `char c = 'A';`, `char *s = "abc";` — local initializers
compile to post-ENT stores), `void` functions (`void f() { return; }`;
`void` variables are rejected), and multi-read file semantics (each `read`
advances a per-fd position). Still unsupported: array initializers
(`int a[3] = {1,2,3};`), array/`void` parameters, multi-dimension arrays,
and non-constant initializers.

Tests (105 checks — probe gate, VM selftest, lexer selftest, and the program
corpus whose exit codes/outputs are cross-verified against the reference
build):

```
matlab.bat tests/run_tests.m
```

## Notes

- `xc.m` is a derivative port of `xc.c` (GPL2, lotabout/write-a-C-interpreter,
  itself derived from c4). `hello.c` is copied from the same repo. The project
  should adopt GPL2 before publishing.
- Known bugs in the MATLAB clone (v1.2.37, fixed across v1.2.38-v1.3.21) are
  tracked in an internal bug report (`docs/2026-08-10-matlab-clone-bug-report.md`,
  gitignored — not shipped with the repo); the port targets v1.3.21, follows
  real MATLAB semantics, and avoids the remaining quirks defensively.
