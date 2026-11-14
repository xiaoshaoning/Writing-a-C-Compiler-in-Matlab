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

### M0 — inventory and scaffolding — DONE (2026-11-05)
- [x] Mnemonics, directives, registers and operand shapes measured (above)
- [x] `src/ma_asm.m`: parses lines, sections, labels and directives; `.byte/.long/.short/
      .quad/.string/.comm/.globl` implemented; every instruction fails with either
      `line N: unknown mnemonic <x>` (not in the table) or
      `line N: no encoder for <x> yet (M3)` (in the table, M3 owns it)
- [x] ISA table: one row per measured mnemonic, with the encoder family it needs
- [x] `tests/probe_assembler.m`: `as` + `objcopy`, **prefix-wise** diff, both lengths
      printed, `as` refusing a program reported as "not a test of this assembler"
- [x] Both runtimes agree on all four demonstration cases: a one-instruction sample
      (`reference 16 bytes, ours: line 4: no encoder for leaq yet`), a directives-only
      file (`MATCH`), an unknown mnemonic (`line 1: unknown mnemonic frobnicate`), and a
      known mnemonic with no encoder

**Three MATLAB-portability findings from building M0**, each of which silently produced
wrong behaviour rather than an error, and each now avoided:

| construct | clone behaviour | used instead |
|---|---|---|
| `sscanf(..., 4)` (the next-index output) | returned something that indexed as 0 | plain character scanning |
| `regexp(s, '...', 'end')` | returned empty | plain character scanning |
| `regexp(txt, '?
', 'split')` | returned the WHOLE text as one line - so `ma_asm` assembled nothing and reported success | split by `char(10)` by hand |

The third is the dangerous one: a split that quietly returns one element makes an
assembler that produces an empty image and says it worked. Any new MATLAB module in this
repo should assume `regexp` options beyond `'match'` and `sscanf`'s fourth output are not
available on the clone, and prefer scanning.

A fourth is about the *engine*: its `system()` rejects an absolute path handed to `as`
("can't create ...: Invalid argument") and does not accept cmd's `cd /d`, so the probe
passes bare names in the working directory - the suite's existing `tmp_*` convention.

**And five findings from reviewing M0 an hour after writing it**, all in new code:

| finding | what it would have done |
|---|---|
| `struct('name', {})` as an empty struct array | the clone makes a ONE-element struct, so every symbol list started with a phantom. Empty arrays differ per runtime; the symbol table is now a **cell** of structs, which is not |
| `e == '\'` in the `.string` escape | `'\'` is TWO characters in MATLAB, so the comparison never matched - with 31 corpus strings containing an escaped backslash |
| `sscanf('%d,')` for data values | stops at the first unreadable value, so `1, 0x10` became `1` and the rest vanished into the image |
| `.globl f` plus a later `f:` | two symbol entries for one symbol, one of them with no offset |
| the probe printing `MATCH` for a zero-byte comparison | an assembler that emitted nothing reported success - the same lie the harness exists to prevent, now `VACUOUS` |

Also added: GAS's single-character escapes (`   `). `cc_int` emits none of
them, but the reference assembler accepts them, and refusing what `as` accepts makes the
two disagree for a reason that is ours rather than C's.

### M1 — lines, labels, directives — DONE (2026-11-05)
- [x] Strip comments and blank lines; line numbers kept for errors
- [x] Label definitions recorded with a section and an offset
- [x] `.text` / `.data` switching; `.globl <sym>` marks a symbol global
- [x] `.file` / `.def` / `.scl` / `.type` / `.endef` / `.cfi_*` accepted and ignored
- [x] `.byte` `.short` `.long` `.quad` `.string` emit bytes, decimal and hex accepted, and
      a value the scanner cannot read is REFUSED with its line rather than dropped
- [x] `.comm <sym>,<len>,<align>` recorded as a zero-initialised symbol
- [x] **Gate:** `tests/asm/m1_data.s` exercises every one of them, and the probe compares
      `.data` and `.text` byte for byte against `as`: `data MATCH (22 bytes)`,
      `text MATCH (1 byte)` on both runtimes

**The padding lesson, learned twice.** `.data` is padded to a section boundary exactly as
`.text` is - a 22-byte section comes back as 32 - so the first version of the data
comparison reported a length mismatch where the bytes were right. Both sections now go
through one `compare_bytes`, so the rule lives in one place and the mistake has one place
to be made.

**Deferred on purpose:** label *offsets* are recorded but not yet compared. They become
comparable at M4, where a relocation is a displacement against a label's final address -
comparing them now would be checking a number nothing uses yet.

### M2 — operand decoding — DONE (2026-11-05)
- [x] Six forms, measured over 25 programs and 11157 instructions: `%rax`, `$12` / `$-1` /
      `$0x10`, `-1004(%rbp)`, `(%rax)`, `.Lret1` / `main`, `a(%rip)`
- [x] A register table with number, width and REX need - the measured set, not x86-64
- [x] The decoder is a real pipeline stage, not a library: every instruction's operands are
      decoded before the encoder gate, so an unreadable form fails with its LINE instead of
      surfacing later as bad bytes
- [x] **Gate:** all 25 sample programs reach the encoder gate with 0 decode failures, on
      both runtimes

The "no 64-bit immediate-to-memory" rule and the 0F-family encoders belong to M3, where
bytes exist to be wrong; the decoder only has to say *what* an operand is.

**The gate found an M1 bug on its first run.** All 25 programs died at line 6 with
`unknown directive .LFB1`: ma_asm decided label-vs-directive by testing `line(1) == '.'`,
and every local label (`.Lret1`, `.LFB1`, `.Lstr0`) starts with a dot exactly like a
directive does. Nothing in the M0/M1 fixtures had a dotted label - they all used `main:`,
`gvar:`, `tail:` - so the whole class was invisible until the corpus-wide run. The
decision is now made by scanning the name at the start of the line ONCE and asking whether
a ':' follows, which is what the line actually means.

### M3 — encoders, most-frequent first
Order matters: `movq movslq leaq pushq popq addq` are **8266 of 11157 instructions
(74.1%)** across the sample, so getting those six right makes M3 measurable long before
the tail is covered.

- [x] `movq` (reg↔reg, mem↔reg, imm↔reg, imm↔mem) — byte-identical to `as`
- [x] `leaq` with `N(%reg)` and `sym(%rip)` (the rip displacement is zero until M4)
- [x] `movslq` (mem and register sources)
- [x] `addq` (reg, mem, and all three immediate forms including the accumulator short form)
- [x] `pushq`/`popq`/`ret`
- [x] `movl`/`movb` (same family, different widths) — and the immediate-to-register opcode
      differs by width: `c7 /0` for movq, `b8+rd` for movl, `b0+rb` for movb
- [x] the ALU family: `addq subq cmpq andq orq xorq xorl` (one shape, six opcode sets,
      width from the suffix; accumulator short forms)
- [x] `notq negq incq` (F7/FF group) and `shlq shrq sarq` (including shift-by-one D1 and
      count-in-%cl D3)
- [x] `movslq movsbq movzbl` — and `movslq` is the single-byte `63 /r`, NOT a 0F form
- [x] `movabsq`, `cqto`, `divq`/`idivq`, `testb`, and the eight `setcc` forms
Every one of those is also done now, including the SSE row and the branch family; the gate
below is the statement of it. This list used to repeat six of the items above it with the
opposite tick, which is what a checklist does when it is written as a to-do and then never
edited again.
**M3 progress (2026-11-05): six mnemonics, verified byte for byte.** A 23-instruction file
covering every operand shape the corpus uses encodes to the same 80 bytes as `as`. The
choices are the reference's, measured rather than derived from a manual, and three of them
differ from what a careful reading of the encoding tables would produce:

| instruction | as emits | the "obvious" answer |
|---|---|---|
| `movq %rax, %rbx` | `48 89 c3` (89, reg=source) | `48 8b d8` (8B) — 8B/03 are only for a MEMORY source |
| `addq $500, %rax` | `48 05 f4 01 00 00` | `48 81 c0 …` — the accumulator short form |
| `movq %rax, %r8` | `49 89 c0` (REX.B) | `4a 89 c0` if the r/m high bit goes in REX.X |

The byte gate found all three within minutes of each other, which is the whole argument for
building it before writing encoders.

Corpus status: **0 of 25 sample programs assemble fully**; all 25 reach the
missing-encoder wall with no decode or encoding failures on the way. 45 mnemonics to go,
and `movl`/`movb`/`testb`/the branches/setcc/SSE remain in families M3 already has helpers
for.

**A structural note for the rest of M3.** `enc_rm` is an if-chain over four mnemonics. At
twenty it becomes the kind of method nobody can hold in their head, and the ISA table is
already the right place to say which family a mnemonic belongs to: `kind` should grow
finer (`mov`, `lea`, `movsx`, `alu-add`, `alu-sub`, `shift`...) so each encoder is a
function of *one shape* rather than of a list of names. `ret` was the first evidence - it
was dispatched by `strcmp(mn, 'ret')` and is now a table kind, which is one special case
fewer and one more row of data.

**Review of this slice, three findings, all in code an hour old:**

- the `movq $imm, %reg` path hardcoded REX 72/73 instead of asking `rexp` - the same
  duplication that had just put the B bit in X, fixed twice in one hour for the same reason
- `ret` dispatched by name instead of by table kind
- `mod_low` had no guard against a sentinel: `mod_low(-2)` is 6, which quietly encodes
  `%rsi`. Every caller checks first; it now says so instead of relying on that

**M3 status (2026-11-05, second batch): 30 of 51 mnemonics, two files of instructions
byte-identical to `as`.** A 39-instruction file covering every new shape encodes to 139
bytes identical to the reference, and the original 23-instruction file still matches at 80.

Corpus: **1 of 25 sample programs assembles fully** (was 0), 24 stop at a missing encoder,
0 fail for any other reason. What they ask for, in the order they hit the wall:

    je 8   imulq 5   jne 3   jg 2   jge 2   movsd 2   call 1   jbe 1

Five of those eight are branches, and a branch cannot be encoded without knowing the
distance to its label - so the corpus is now blocked on **M4, not on more encoders**. The
rest (`imulq`, `movsd`) are two small family additions to do alongside it.

**Four bugs the byte gate caught in this batch**, all mine, all invisible to reading:

| what | why |
|---|---|
| `movslq` encoded as `0F 63` | it is the single-byte `63 /r`; my refactor had folded it in with the two genuine 0F forms |
| `movl $5, %eax` as `B0` | `B0+rb` is 8-bit; 32-bit is `B8+rd`, and 64-bit is `c7 /0` - three forms, one per width |
| `movabsq` as `B0+rd` | the same slip, in the `misc` family instead |
| `xorl` had no table row | the ALU spec is keyed by mnemonic, and I had only added the `q` suffix forms |

And one from reviewing the batch: `enc_shift` accepted **any** 8-bit register as a shift
count. `D3` takes the count from `%cl` implicitly - the encoding has no field for it - so
`shlq %al, %rax` would have been encoded as `shlq %cl, %rax` and meant something else
entirely. It requires `%cl` by number now. A wrong-byte bug that no byte comparison in this
project could catch, because the reference assembler refuses the input.

### M4 — layout and relocations — DONE on the 25-program sample (2026-11-05)
- [x] Parse into ITEMS (bytes, label, branch/call), not bytes: a branch's size depends on
      where its target lands, so it cannot be encoded while parsing
- [x] Iterate to a fixed point, shrinking branches that fit: `as` picks the SHORT form even
      for a forward reference (measured: `jmp` to a label 23 bytes ahead is `eb 15`), so the
      form of one branch moves the offsets of everything after it
- [x] `call` is always `e8 rel32`; a call to a symbol outside the section emits zeros,
      because that is what the reference emits (the shims reach the real printf/malloc)
- [x] A branch to an unresolved label is refused; an external CALL is not an error
- [x] Resolve rip-relative references to SAME-SECTION labels. A reference to another
      section stays 0 - measured: `leaq .Lx(%rip)` with .Lx in .data is `48 8d 05 00 00 00
      00` plus a relocation. The operand carries its own `.ripdisp`, filled in by the emit
      pass, so resolving costs no argument threading.
- [x] `movq $imm, reg` uses `c7 /0 id` only when the value survives SIGN-extension from 32
      bits, else `movabs` (10 bytes). Measured: `movq $5` is `48 c7 c0 ...`, `movq
      $0xb2d05e00` is `48 b8 ...` - the long form is not optional, the short one would store
      a DIFFERENT number.
- [x] `movq $imm, mem` TRUNCATES to 32 bits, because `as` does. Refusing was stricter than
      the reference and broke a corpus program it assembles.
- [x] `movb` has its own opcodes, `88`/`8A`; using the 32-bit pair moved a different number
      of bytes and looked entirely plausible. Cost one program at byte 88.

- [x] `imulq`: three shapes (`F7 /5`, `0F AF /r`, `6B`/`69 /r`) - and the THREE-operand
      form, which I first encoded as the two-operand one. `imulq $3,%rsi,%rax` came out as
      `imulq $3,%rsi`: a different multiplication, plausible-looking bytes. Only the
      hand-written fixture exposed it; no corpus program uses that form.
- [x] `movsd` and the XMM registers, which the register table distinguishes by width 128
      rather than by a new field. `movsd %xmm0,%xmm1` uses the LOAD opcode, measured.
- [x] REL32 against another section stores an ADDEND, not a distance, and which addend
      depends on whether the symbol has a section yet:
      `.comm` -> 0 (symbol relocation; its section is decided at link time);
      `.data` symbol -> its offset within `.data` (`h` at `.data+0x10` stores `0x10` from
      `.text+0xc5`); undefined -> 0. Read off the reference's own relocations, and it is
      why `.data` must be laid out before `.text`.
- [x] `.comm name,size,align` scanned by hand: `sscanf`'s first output is a STRING, so
      `[parts, count]` concatenated the name and the count into one char array.
- [x] Mnemonics may contain digits - the scan stopped at the first non-letter, so
      `cvtsi2sdq` arrived as `cvtsi` and was reported as an unknown mnemonic.

- [x] `call *%rax` (`ff /2`) - an indirect call through a register or a memory slot. A
      DIRECT call still never reaches an encoder: the layout owns its displacement.
- [x] The `(%rsi,%rcx)` decoder gap was `split_operands` splitting on commas inside
      parentheses, so the operand arrived as `(%rsi`. Commas now split only at depth 0, and
      the SIB form is decoded (base, index, optional scale) and encoded with REX.X.
- [x] `movq` between a GPR and an XMM: `66 REX.W 0F 6E/7E`, and XMM-to-XMM is `F3 0F 7E` -
      the same opcode as a load with a different prefix. The `movsd` family gained a
      per-mnemonic [prefix, w, opcode, store-opcode] row, so `divsd`, `mulsd` and `ucomisd`
      are one line each.
- [x] **cc60_scalar_literal was `movb $imm, memory`.** I emitted `C7 /0 id` (7 bytes)
      where the reference emits `C6 /0 ib` (4). The same byte-width pair that cost one
      program at the `88`/`89` opcodes, in the immediate-to-memory form. It also means my
      earlier "per-instruction sizes agree" conclusion was wrong: that test aligned the two
      instruction lists by MNEMONIC NAME, which silently skips entries and reports agreement
      between things that are not the same instruction. Comparing by position found it
      immediately.
- [x] **imm64 literals keep their hex digits.** `movabsq $0x999999999999999a` came out as a
      different number at the right length, because the literal went through a MATLAB double
      and 53 bits cannot hold 64. `le_bytes_imm` builds the eight bytes from the digits the
      source wrote.
- [x] `cvttsd2siq`, and `addsd`/`subsd`/`mulsd`/`divsd`/`ucomisd` - one row each. The flag
      that distinguishes `cvtsi2sdq` from `cvttsd2siq` is which operand sits in the ModRM reg
      field: same prefixes, same shape, opposite meaning.

**Gate, measured (the clone): 25 of 25 byte-identical, 0 differ, 0 missing an encoder,
0 errors.** The whole sample assembles to exactly what `as` produces.

**Filed in the engine repo:** `matlab_in_rust/docs/BUG_REPORT_2026-11-05_engine_char_index_command_name.md`
- the defect below, with the two-line reproducer and the test to add.

**Open: the engine cannot verify the sample yet.** `ma_asm` on the engine throws an error
whose message is a bare command name when the input contains one. Reproducer:
`.string "exit"` fails with `m=[exit]`; `.string "quit"` the same; `.string "EXIT"` the same;
`.string "exitx"`, `"abcd"`, `"return"` and `"e x i t"` are all fine. So it is a string whose
whole value is a COMMAND name, not a prefix or a substring. `cc17_shim` contains `call exit`,
which is why the engine run stops at 5 of 25 files. The clone assembles all 25 identically,
so this is an engine defect to isolate, not an assembler one - and it blocks the two-runtime
discipline that has caught every earlier bug in this project.

**An engine/clone portability finding, and the sneakiest yet:** growing a struct array with
`tab(end+1) = add(...)` CORRUPTS it on the clone - three rows became four and every `.name`
returned the new one - while the engine keeps them correct. Silent, and it is the opposite
direction from the usual clone-accepts/engine-refuses pattern.

**Previous gate, for the record:** 7 byte-identical, 2 differ, 14 missing an encoder,
2 errors. The branch fixture is byte-identical (463 bytes: short forward, near
forward, short backward, near conditional, and a call).

**An engine portability finding:** `items{j}.short = 1` and `items.(section){end+1} = it`
are chained assignment targets. The clone accepts them; the engine refuses with "indexed
assignment base must be a variable". Several helpers now use a temporary, and there is a
`push_item` for the section list. That is the sixth harness-level portability difference
found by running the same code on both.

### M5 — the gate
- [x] **338/338 byte-identical `.text` against `as`.** Every corpus program, `.text` for
      `.text`. Nothing on the 25-program sample predicted this: the sample was chosen from
      forms I had already met, and the corpus found five more (`movw`, `movzwl`, `movswq`,
      `movzbq`, `movsbl`), `.quad symbol` as an address rather than a number, and - the one
      that would have hidden longest - `movq $9223372036854775807, %rax`, a DECIMAL literal
      beyond double precision. `cc_int` emits decimal, not hex, so "carry the hex digits" was
      only half a fix: `decimal_bytes` now reads the digits by long division.
- [x] A `CC_SECTIONS=asm` group in `run_tests.m` running M5 as one check: `PASS asm: 338 of
      338 corpus programs byte-identical to as`.
- [x] Error cases asserted the way `cc_bad_*` are - `tests/asm_errors.m`, ten inputs, each
      asserted on the CAUSE in the message rather than on something having been thrown: an
      unknown mnemonic, an unresolved branch target, a malformed operand, a shift by a
      register that is not `%cl`, an SSE register in a general-register operation an
      immediate wider than 64 bits, a label sharing a line with an instruction, an indirect
      jump, a `.comm` with no size, a `.string` ending in a backslash. These are the cases
      where being wrong is SILENT, so they are worth more than their count: `shlq %al,%rax`
      was once encoded as `shlq %cl,%rax`, and `jmp %rsi` was once reported as "unresolved
      symbol " with an empty name. They call nothing but `ma_asm`, so they are not behind
      the gcc guard - that is where they would vanish on exactly the machine where they
      still work.
- [x] Suite totals: `CC_SECTIONS=none` 153/153, `CC_SECTIONS=asm` 154/154.
- [x] **338/338 on the ENGINE as well as the clone** (2026-11-05, `cli-v21-5-g9dc5345`).
      The two-runtime discipline applied to the assembler at full corpus scale for the
      first time: `asm_gate()` needs no runtime-specific handling, so both agree. On the
      engine this needed a current binary - the `dist/` copy was two days older than the
      `exit` fix, and the same `call exit` that the assembler handles is what found the
      engine defect.

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
3. ~~First-pass size estimation.~~ **Settled by construction, differently than planned.**
   There is no sizing pass to get wrong: a branch starts at its longest form and only ever
   shrinks, and every other item's size is exact the moment it is parsed. Offsets are then
   computed from those sizes by one function (`item_offsets`) that both the relaxation and
   the emit pass use, so there is no second opinion to disagree with.
4. **Immediate width and `movabs`.** The project already hit the 64-bit-immediate-to-memory
   limit once. *Settles it:* byte comparison on `dreg_denselit.c` and `cc49_long.c`.
5. **Effort.** This is the honest one: M1–M3 is mechanical and slow — roughly 51 encoders
   at a few lines each, plus a table. Estimate **a week of sessions**, with M5 as the
   only meaningful intermediate signal.

## Definition of done

`ma_asm` turns any `.s` that `cc_int` produces into bytes identical to `as`, proven by a
check in the suite that runs on every corpus program; every failure mode it can hit names
the line; and the compiler is unchanged, because the seam did not move.
