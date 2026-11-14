# Plan — an assembler for the text `cc_int` emits

**Status:** plan, not started. Written 2026-11-05, after `v1.6.0`.

## Why, and what it is not

`cc_int` emits **text assembly** and hands it to `gcc`, which quietly does three jobs:
assemble, link, and supply a C runtime. `x86sim` covers the "run it without gcc" half by
interpreting that text directly.

What is missing is the middle: turning our own text into **machine code**. That is the
assembler. It is a good next project because it is (a) bounded — the input language is
exactly what `cc_int` produces, and that set is measured below, (b) verifiable to the byte
against a reference assembler, and (c) at a layer below the compiler, so nothing about the
compiler changes.

It is **not** a linker, not a PE/ELF writer, and not a runtime. Those are separate
projects, in that order, and each only becomes worth doing when the one before it exists
and is trusted.

## Scope: the input language, measured

Not guessed. Twenty-five diverse corpus programs were compiled with `cc_int` and their
`.s` inventoried: 25 files, every mnemonic and directive counted.

**51 mnemonics.**

| family | mnemonics |
|---|---|
| moves | `movq` `movl` `movb` `movabsq` `movslq` `movsbq` `movzbl` `movsd` |
| address | `leaq` |
| stack | `pushq` `popq` |
| arithmetic | `addq` `subq` `imulq` `idivq` `divq` `negq` `incq` `cqto` |
| logic | `andq` `orq` `xorq` `xorl` `notq` `shlq` `shrq` `sarq` |
| compare/test | `cmpq` `testb` |
| branches | `jmp` `je` `jne` `jg` `jge` `jl` `jle` `ja` `jae` `jbe` |
| calls | `call` `ret` |
| setcc | `sete` `setne` `setg` |
| SSE | `mulsd` `divsd` `addsd` `subsd` `ucomisd` `cvtsi2sdq` `cvttsd2siq` |

**15 directives**, of which two groups are ignorable by design:

| directive | use | v1 |
|---|---|---|
| `.text` `.data` `.string` `.byte` `.long` `.comm` `.globl` `.file` | sections, data, symbols | **encode** (all but `.quad`/`.short` observed in the sample) |
| `.quad` `.short` | 8- and 2-byte data | **encode**, but *not* observed in these 25 programs - expected from `long long`/`short` globals, to be settled by the full-corpus run at M4 |
| `.def` `.scl` `.type` `.endef` | COFF debug metadata gcc emits | **ignore** |
| `.cfi_startproc` `.cfi_endproc` `.cfi_def_cfa*` `.cfi_offset` | unwinding metadata | **ignore** |

**Registers:** `%rax %rbx %rcx %rdx %rsi %rdi %rbp %rsp`, `%r8`–`%r11`, `%eax %ebx
%edx`, `%al %cl %dl`, `%xmm0 %xmm1`, `%rip`.

**Operand shapes** (top forms by frequency): `$imm, %reg` · `%reg, %reg` ·
`N(%reg), %reg` · `%reg, (%reg)` · `%reg, N(%reg)` · `sym` · `sym(%rip)` · `$imm` alone.

Two facts from the inventory that shape the design:

1. **No cross-object relocations are needed.** Every program is one translation unit, and
   the libc calls go through shims (`__cc_<name>_<nargs>`) that `cc_int` emits *in the
   same file*. `call`/`jmp` targets are internal labels. That removes symbol resolution
   between objects from v1 entirely.
2. **`.quad` appears in the survey only inside `.data`/`.comm` images**, and `.string`
   only for literals, so the data encoders are simple byte emitters.

## Interface (designed twice, as the project's rule says)

**A — a class with methods.** `Asm().addLine(...)`, `.bytes()`, `.symbols()`. Rejected:
MATLAB without classes leaves this as a struct of closures; the state would be public and
the call order would matter. A class wrapper around one function is the "shallow module"
red flag.

**B — one function, image out.**

```matlab
img = ma_asm(txt)      % txt: the .s text (char or cellstr of lines)
% img.text   uint8 row: the .text bytes
% img.data   uint8 row: the .data bytes (as written, unaligned; layout is the caller's)
% img.bss    struct array: .name .size .align
% img.syms   struct array: .name .section .offset .global
% img.errors (thrown instead - see below)
```

**Chosen: B.** One call, one value, no state to sequence, and the seam is *text in, image
out* — the same deliberately cheap seam the compiler uses. It can be exercised from a
one-liner, compared against `as` without a file system, and wrapped in a file-reading
three-liner later if that is ever wanted.

Errors: **throw** with `line N: <what>` on the first bad line. A collector variant is a
knob nobody asked for; when several errors per file matter, it is a different function.

The ISA knowledge — opcode bytes, operand patterns, encoder kind — lives in **one table**
(a struct array indexed by mnemonic), so a new instruction is one row and no code change.
That is the module's whole depth: 51 rows of data behind one call.

## Output: what "done" means for v1

**Byte-identical `.text` against the reference assembler, for every corpus program.**

No PE/ELF, no loader, no runtime. Byte equality with `as` on 338 programs is stronger
evidence than any of those would be, and unlike them it can be checked automatically.

## Verification plan

Two oracles, both already installed:

1. **`as` (via `gcc -c`) + `objcopy -O binary`.** Assemble the same `.s` with the
   reference toolchain, extract the section bytes, compare with `img`. Per program, and
   reported as a count, like `gcc stdout: 335/335 byte-identical` is today.
2. **`x86sim`** for execution, unchanged: it already runs the text, so a program that
   still runs correctly through `x86sim` after any refactor of the emitter keeps its
   behavioural check. (The assembler does not feed `x86sim` in v1; the point is that the
   suite's existing checks stay valid throughout.)

A byte mismatch is reported with the offending line and the first differing byte offset —
the same "print both sides" discipline that broke the parity deadlock earlier.

**Measured while writing this plan, because it would have produced a false failure on
every program:** the reference bytes are PADDED. Assembling the five-byte
`leaq 1(%rdi),%rax; ret` and extracting `.text` yields 16 bytes —
`48 8d 47 01 c3 90 90 …` — because gas aligns the section. The comparison must therefore
be prefix-based up to the meaningful length (the last symbol's end, or `img.text`'s own
length), never whole-section equality. Both `objcopy -O binary --only-section=.text` and
the `as`/`objcopy`/`objdump` binaries are present in the MSYS2 toolchain; writing to a
file, not `/dev/stdout`, is the working form on Windows.

## Milestones (checklist)

### M0 — inventory and scaffolding
- [x] Mnemonics, directives, registers and operand shapes measured (above)
- [ ] `src/ma_asm.m` exists; unknown mnemonic fails with `line N: unknown mnemonic <x>`
- [ ] ISA table skeleton: one row per mnemonic with its encoder kind
- [ ] Test harness `tests/probe_assembler.m`: assemble a program's `.s` with `as`, extract
      `.text` with `objcopy`, diff against `ma_asm` **prefix-wise** (the reference is
      padded to 16 bytes), print the first difference

### M1 — lines, labels, directives
- [ ] Strip comments and blank lines; keep line numbers for errors
- [ ] Label definitions (`.L<n>:`, `<sym>:`) recorded with a section and a provisional offset
- [ ] `.text` / `.data` section switching; `.globl <sym>` marks a symbol global
- [ ] `.file` / `.def` / `.scl` / `.type` / `.endef` / `.cfi_*` accepted and ignored
- [ ] Byte emitters for `.byte` `.long` `.string` (observed) plus `.short` `.quad` (expected, unobserved)
- [ ] `.comm <sym>,<len>,<align>` recorded as a zero-initialised symbol

### M2 — operand decoding
- [ ] Registers → ModRM/REX; `$imm` (decimal, `$0x..`); `N(%reg)`; `(%reg)`;
      `sym(%rip)`; bare `sym`/label → a relocation record
- [ ] Immediate width rule: x86 has no 64-bit immediate-to-memory form (this bit the
      project already: `movabsq` through a register)
- [ ] Sign/zero-extension forms (`movslq`, `movsbq`, `movzbl`) map to one 0F-family encoder

### M3 — encoders, most-frequent first
Order matters: `movq movslq leaq pushq popq addq` are **8266 of 11157 instructions
(74.1%)** across the sample, so getting those six right makes M3 measurable long before
the tail is covered.

- [ ] `movq`/`movl`/`movb` (reg↔reg, mem↔reg, imm↔reg, imm↔mem)
- [ ] `leaq`/`lea` with `N(%reg)` and `sym(%rip)`
- [ ] `pushq`/`popq`/`ret`/`call`
- [ ] `addq`/`subq`/`cmpq`/`andq`/`orq`/`xorq` (imm and reg forms)
- [ ] `jmp`/`jcc` (rel8 and rel32), `setcc`
- [ ] `imulq` (imm,reg), `idivq`/`divq`/`cqto`, `negq`/`notq`/`incq`
- [ ] `shlq`/`shrq`/`sarq` (imm and `%cl`)
- [ ] `movabsq`, `testb`
- [ ] SSE: `movsd`/`mulsd`/`divsd`/`addsd`/`subsd`/`ucomisd`/`cvtsi2sdq`/`cvttsd2siq`

### M4 — layout and relocations
- [ ] Two passes: sizes first, then addresses (forward references need it; `.string`
      lengths make the first pass non-trivial)
- [ ] Internal relocation resolution: `call`/`jmp`/`jcc`/`lea sym(%rip)` → displacement
      against the final address
- [ ] Reject an unresolved symbol with its line, rather than emitting a zero displacement
- [ ] Assemble all 338 corpus programs; report byte-identical count

### M5 — the gate
- [ ] 338/338 byte-identical `.text` against `as` (or a written-down, justified list of
      exceptions with the reason each differs)
- [ ] A `CC_SECTIONS=asm` group in `run_tests.m` running M5 as one check
- [ ] Error cases asserted the way `cc_bad_*` are: an unknown mnemonic, an unresolved
      symbol, a bad operand — each with its message

### Later, deliberately out of v1
- [ ] Section layout and an executable image (PE on Windows) — a new project
- [ ] A flat-binary loader for `x86sim` — makes the binary *useful*, and depends on the
      above
- [ ] Multi-file: relocations between objects, a symbol table across them
- [ ] A linker — see the discussion in `PROJECT_STATUS.md`: it needs objects first, and
      it costs the text seam that makes this toolchain verifiable

## Risks, each with the measurement that settles it

1. **The inventory is a sample, not the corpus.** 25 programs, 51 mnemonics. *Settles it:*
   M4 assembles all 338 and reports every unknown mnemonic it meets. If the full set is
   larger, the table grows by rows, which is why it is data.
2. **`.string` escaping.** GAS escapes are not C escapes, and `cc_int` already escapes
   for GAS. *Settles it:* the byte count of `.string` output compared with `as` on
   `cc22_escapes.c` and `cc18_strbslash.c`, the two programs that exist for this.
3. **First-pass size estimation.** `.string` and `.quad` lengths decide offsets, so the
   first pass must be exact, not approximate. *Settles it:* two-pass disagreement is
   detected by construction (pass 2 asserts the offset it computed matches).
4. **Immediate width and `movabs`.** The project already hit the 64-bit-immediate-to-memory
   limit once. *Settles it:* byte comparison on `dreg_denselit.c` and `cc49_long.c`.
5. **Effort.** This is the honest one: M1–M3 is mechanical and slow — roughly 51 encoders
   at a few lines each, plus a table. Estimate **a week of sessions**, with M5 as the
   only meaningful intermediate signal.

## Definition of done

`ma_asm` turns any `.s` that `cc_int` produces into bytes identical to `as`, proven by a
check in the suite that runs on every corpus program; every failure mode it can hit names
the line; and the compiler is unchanged, because the seam did not move.
