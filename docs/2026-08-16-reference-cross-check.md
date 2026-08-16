# Reference Cross-Check — 2026-08-16

Verification of the parity claims against the reference implementation,
`D:\Projects\github\write-a-C-interpreter\xc.c` (lotabout's xc, the
source for the xc.m port).

## Setup

```
cd D:\Projects\github\write-a-C-interpreter
gcc xc.c -o xc_ref.exe          # fresh reference build (156,793 bytes)
./xc_ref.exe hello.c            # the vendored hello.c
```

The prebuilt `xc.exe` in that directory was also compared.

## Results

### 1. hello.c stdout — BYTE-IDENTICAL

`xc_ref.exe hello.c` vs `xc.m tests/programs/hello.c` (same code, modulo a
comment header): both produce **221 bytes**, identical — the fibonacci
table `fibonacci( 0) = 1 … fibonacci(10) = 89` plus the trailing
`exit(0)` with no final newline.

The prebuilt `xc.exe` produces the same stdout.

### 2. `-s` instruction dumps — identical modulo address operands

Both produce 84 dump lines / 65 instructions with identical opcode
sequences. The only differences are **5 address operands**:

| instruction | reference | xc.m |
|---|---|---|
| `CALL` (fibonacci ×3) | absolute text address (e.g. 910380712) | slot index (1) |
| `IMM` (string literal) | absolute memory address (910642864) | 0 |
| `JMP` (loop back-edge) | absolute address (910381112) | slot index (51) |

These are build-dependent: the fresh build and the prebuilt `xc.exe`
differ in exactly the same operands (their addresses differ). The port
stores slot indexes in its text segment by design (index-based VM), so
the operands cannot match byte-for-byte; the opcode stream and all other
operands (LEA offsets, ENT sizes, JZ/JNZ targets as indexes…) agree.

### 3. Bug found and fixed during the check

The port emits a function's `ENT` (frame) instruction *before* its local
declarations with a placeholder size, backpatched after — needed so local
initializer expressions run after the frame exists. The reference emits
`ENT <size>` *after* the declarations. Consequences for the `-s` dump:

- the reference prints the ENT (final value) under the first statement
  line; the port printed the placeholder `ENT 0` under the declaration
  line;
- `ENT`'s operand was dumped as 0 even when the frame was 1.

`function_body` now matches the reference: the declarations are parsed
first (initializer code buffered in `text`), the `ENT` is emitted with the
final size, and the initializer code is spliced back in afterwards — so
the runtime frame-first guarantee is unchanged and the dump matches.
Two off-by-one indexing bugs in the splice (slot-vs-text positions) were
caught by the initializer regression tests (`pp_nonconst*`, `pp_init*`).

## Verdict

Both PROJECT_STATUS claims hold: hello.c stdout is byte-exact, and `-s`
dumps are identical modulo the absolute-address operands (which even vary
between builds of the reference itself).
