# Project Status — 2026-08-10

## Summary

**Interpreter track (`xc.m`): complete.** A single-file MATLAB port of
lotabout's [write-a-C-interpreter](https://github.com/lotabout/write-a-C-interpreter)
(`xc.c`, itself derived from c4): lexer → recursive-descent parser with
on-the-fly codegen → 38-opcode stack VM → syscalls. All seven planned phases
are done, plus six post-parity features beyond the reference dialect.

**Assembly track (`cc_int.m`): part 1 only.** Compiles `return <int>;` to
x86-64 COFF assembly (Norasandler series), verified end-to-end through gcc.

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

## Verification

- **Test suite**: `tests/run_tests.m` — **111/111** on the target runtime.
  Groups: runtime-primitive gate (probe), 26-case VM selftest, 9-case lexer
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
- Constant initializers: `int x = 5;`, `char c = 'A';`, `char *s = "abc";`
- `void` functions: `void f() { return; }` (void variables rejected)
- Multi-read file semantics: repeated `read()` calls advance a per-fd
  position

## Known limitations (documented dialect gaps)

- Array initializers (`int a[3] = {1,2,3};`)
- Array/`void` parameters, multi-dimension arrays
- Non-constant initializers (`int a = g;` where `g` is a variable)
- `sizeof` on array names; `%s` with length modifiers
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
   Notes.

## Running

```
D:\...\matlab.bat tests/run_tests.m          # full suite (111 checks)
D:\...\matlab.bat -batch "xc('tests/programs/hello.c')"   # acceptance program
D:\...\matlab.bat -batch "xc('-s', 'tests/programs/hello.c')"  # compile dump
D:\...\matlab.bat -batch "xc('-d', 'tests/programs/hello.c')"  # trace
```

See `README.md` for both tracks and the layout.
