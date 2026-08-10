# Writing-a-C-Compiler-in-Matlab

Building compilers/interpreters in MATLAB, following two classic tutorials:

1. **Assembly track** (`cc_int.m`) — Norasandler's [Writing a C
   Compiler](https://norasandler.com/2017/11/29/Write-a-Compiler.html):
   compiles C to x86-64 assembly. Currently part 1: `return <int>;`.
2. **Interpreter track** (`xc.m`, planned) — lotabout's
   [write-a-C-interpreter](https://github.com/lotabout/write-a-C-interpreter):
   a C interpreter with a custom VM, ported to MATLAB. Design and
   implementation plan: [docs/2026-08-10-xc-matlab-port-plan.md](docs/2026-08-10-xc-matlab-port-plan.md).

## Layout

```
cc_int.m              assembly compiler (return N; → x86-64 .s)
xc.m                  C interpreter (planned)
tests/
  run_tests.m         test harness (planned)
  programs/           test C programs
    return_2.c        return 2; (part 1 of the Norasandler series)
    hello.c           fibonacci demo — xc.m acceptance program
docs/
  2026-08-10-xc-matlab-port-plan.md        implementation plan
  2026-08-10-matlab-clone-bug-report.md    bugs found in the MATLAB clone
```

## Running

MATLAB code runs on the custom MATLAB clone:

```
D:\Projects\codes\MATLAB_in_c\release\v1.2.45\matlab.bat
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

Tests:

```
matlab.bat tests/run_tests.m
```

## Notes

- `xc.m` is a derivative port of `xc.c` (GPL2, lotabout/write-a-C-interpreter,
  itself derived from c4). `hello.c` is copied from the same repo. The project
  should adopt GPL2 before publishing.
- Known bugs in the MATLAB clone (v1.2.37, fixed across v1.2.38-v1.2.45) are
  tracked in
  [docs/2026-08-10-matlab-clone-bug-report.md](docs/2026-08-10-matlab-clone-bug-report.md);
  the port targets v1.2.45, follows real MATLAB semantics, and avoids the
  remaining quirks defensively.
