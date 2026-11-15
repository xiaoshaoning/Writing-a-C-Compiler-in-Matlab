# Project Status — last updated 2026-11-05

## Summary

**Current state (2026-11-05): `857 tests, 857 passed, 0 failed` on real MATLAB R2024b.**
Every one of those checks also passes on the engine (the runtime this project is developed
on) and on the C clone used as an oracle. `instr` 23149 (a ceiling, not a target), x86sim
**338/338** exit codes, gcc stdout **335/335** byte-identical, and the assembler **338/338**
corpus programs byte-identical to `as`.
Three artefacts, each complete for its dialect: `cc_int.m` the compiler, `xc.m` the
interpreter, `ma_asm.m` the assembler. What is deliberately not done has its own section at
the end of this file, with the reason for each item - including one the plan's own checklist
now closes rather than leaves open.

**The assembler is complete (2026-11-05).** `src/ma_asm.m` reads the text `cc_int` emits
and hands back an image; `docs/PLAN_assembler.md` is the record. **338 of 338 corpus programs
are byte-identical to `as`**, `.text` for `.text`, on all three runtimes. Ten inputs it must refuse have their refusals asserted on the message, in
`tests/asm_errors.m`, and `CC_SECTIONS=asm` runs the whole thing as one check.

**That number is now the authority's.** The first real-MATLAB run of the assembler was also
the first run that disagreed: it refused 30 corpus programs with 字段名称 ".byte" 无效 - a
`struct('.byte', 1, ...)` field table, which both clones accept and real MATLAB does not. It
is the fourth defect of that class in this project (`@anon3`, `__st1_n`, `.byte`), so it is
now checked statically (`tests/check_field_names.m`, self-tested) rather than by running.

**The runtime comparison is automated, with a baseline (2026-11-05).** `CC_RUNTIMES="<a>;<b>"
bash tests/run_all.sh` runs the suite once per runtime and diffs the FAILURE SETS, which is
the comparison that found every defect here and used to be done by eye. First real runs, engine
against the C clone: `none` agreed at 163/163 each, and `asm` agreed with `PASS asm: 338 of 338
corpus programs byte-identical to as` on BOTH runtimes in one run - so the assembler's corpus
result now rests on three runtimes rather than two, and the third comparison was made by the
tool instead of by eye. The full 857-check comparison has not been run; the engine needs roughly 40 minutes of a
quiet host for it, which is an estimate and not a measurement. The cheap comparison is the
smoke test that proves the mechanism works.

**Green on real MATLAB at 857 (2026-11-05, final): 857 tests, 857 passed, 0 failed.**
The run that measures everything since 832: `cc57`-`cc60` at exit 96, the two negative
checks (`&x = 5` refused, an integer-only compound assignment on a double refused),
x86sim **338/338**, gcc stdout **335/335 byte-identical**, instr **23149**. 832 -> 835 is
the two new guards and one negative check, which is what a count should do.

**And it disproves the `del()` fix.** Two warnings appear, at both call sites that were
expected to be silent:

    警告: 未找到文件或者权限被拒绝
    > 位置：run_tests>del (第 1824 行)      (called from the corpus loop, and gccstdout)

`del()` probes the file for writing and skips it if the probe fails - which does not
predict a failing `delete`. The 832 run was clean by luck, not by fix; the mechanism was
a theory that this run falsifies. The honest options are a scoped
`warning('off','all')` around the delete with the previous state restored (guarded, since
the clones' support for `warning` is not established), or accepting the two lines. It is
cosmetic: nothing failed, and the noise is 2 lines rather than the ~100 that motivated the
helper in the first place.

**Item 4 of the plan, gap 1 of three: compound assignment on doubles (2026-11-05).**
`d /= 4.0` was refused while `d = d / 4.0` worked; the double branch handled `+= -= *=`
and failed on `/=` and `%=` together, lumping a legal operator with an illegal one.
Splitting them exposed a worse bug behind the refusal: `%=`, `<<=`, `>>=`, `&=`, `|=` and
`^=` on a double fell through to the `divsd` at the end of that branch, so `d <<= 2`
**silently divided by 2**. C requires an integer for all six, so they are refused now
with that reason, and `d /= 4.0` compiles and matches gcc (25 for `10.0 /= 4.0` scaled).

Gaps 2 and 3 are still open and are NOT ten-line changes, which is what the plan said:
- float literals in array initializers (`double a[2] = {1.5, 2.5};`) are still
  refused, and an ATTEMPT AT THEM WAS ABANDONED (2026-11-05), which is worth more than
  the estimate it replaces. Measured first: `double a[3] = {1.5, -2.25, 0.1}` emits
  `1, -2, 0` — the values are already integers where the emitter receives them. Two
  defects were found on the way and fixed in the attempt (the vector emitter printed
  `%d` for every element, and the struct image writer had no double case at all - both
  fixed with `cc_d2bits`, and both reverted with the rest), and the output was still
  `1, -2, 0`, so a THIRD place collects initialiser values as integers. The
  candidates are `parse_arr_init`'s `vals` and `aggregate_values`, and which one was not
  proven. Everything was reverted rather than left half-wired: with the parser accepting
  floats and the values still truncated, the compiler would have accepted
  `{1.5, 2.5}` and stored `1, 2` — silently wrong numbers instead of a refusal, which is
  the one trade this project does not make.

  **The diagnostic is worth keeping.** `sprintf('%d', 1.5)` in MATLAB prints
  `1.500000e+00`, not `1`. So the emitted text says where the value was lost: `%e` text
  means a double reached the emitter (a printing bug), and `1, -2, 0` means the loss is
  upstream of it (a collection bug). That single distinction pointed at the wrong half
  of the pipeline and then at the right one.
- pointer compound literals (`(int*){…}`) are refused by depth in the compound-literal
  branch; `(int[]){…}` works.

**A scalar compound literal's value is the object, not its address - fixed
(2026-11-05).** `(int){5} + 1` returned garbage (156, 188, 252 across three builds, so
address-dependent) where C says 6, while `&(int){9}` returned 9 correctly - which is why
it hid, since the one case a person would try is the case where an address is right.

The cause was a single clause: the compound-literal parser's ARRAY branch tested
`cl_isarr || cbase == 0 || cbase == 1`, so every scalar `int` (code 0) or `char` (code 1)
literal took the array path, where a literal's value is its own address. The scalar branch
below it was unreachable for exactly those types. The fix is three lines - test
`cl_isarr` alone, load the stored object in the scalar branch, and consume the `}` that
branch reads for itself - and `&(int){9}` still works because '&' drops that load through
`lvalue_addr`. Guard `cc60_scalar_literal.c` (exit 96) covers the value, the address, a
write through it (a compound literal is an lvalue) and both unchanged forms: array
literals still decay, struct literals still yield their address. Ceiling 23001 ->
**23149**.

**Review of that fix found a second bug in the same branch, and a refusal replaced it
(2026-11-05).** `(double){1.5} * 2.0` is legal C. The scalar branch stored it through the
integer immediate path, which has no 64-bit immediate-to-memory form, so it emitted
`movq $4609434218613702656, -8(%rbp)` - the correct pattern, an instruction the assembler
rejects. An attempt to route it through `movabsq` produced a wrong pattern instead
(`cc_d2bits` of whatever `v` held was not the value the old path had stored), so it was
reverted and the form is now REFUSED with a message pointing at the two ways that do
work (`(double)x`, or a variable). Nothing in the corpus uses it; the choice between a
loud refusal and a possible wrong number is not a close one.

The branch's closing brace is also required now (`expect(125)` rather than a silent
`if token == 125`), so a malformed literal fails at the literal instead of three tokens
later.

**The lesson is the earlier attempt.** Adding a load to that scalar branch changed
nothing, the load never appeared in the output, and I read that as "the branch is not
reached, dead end". It was not a dead end, it was the diagnosis: a fix that changes
nothing means the code is unreachable, and the reason was one clause up. Next time, an
inert edit is evidence about control flow, not a wasted attempt.

**The doubles fix is guarded (2026-11-05, review).** The negative check asserts
`that compound assignment needs an integer`, not the shorter `needs an integer type`:
the bit-field error ends with those same three words, so the loose form would have
passed on the wrong failure - the same substring-too-loose habit as asserting the word
"error". Reviewing it found the gap the
review exists for: `d /= 4.0` was fixed and the six refusals were fixed, and nothing in
the suite would have noticed either regressing. Guard `cc59_double_compound.c` (exit 96)
covers `/=`, `+=` with an int RHS, `-=` and `*=`; the negative check beside
`cc9_badargs` asserts that `d <<= 2` is refused - the case that used to divide by two in
silence. Ceiling 22884 -> **23001**.

Also measured, because `spec_of` runs on every emitted instruction and `em` is the
hottest function in the compiler: 8 programs compile in 18.6-21.2 s with it and
18.3-19.0 s without, so the classification costs nothing the noise can resolve. The first
single-run comparison said the opposite (41 s vs 19 s) - the first invocation on this
runtime pays a warm-up, so a single timing here is worthless and two alternating runs
are the minimum.

**Function-pointer members work, and the cause was not where I said (2026-11-05).**
Earlier notes blamed `lvalue_addr` for the member miscompile. Measuring proved that
wrong: the member access never reached it. Six places spelled out "is this a struct
value?" by hand as `t >= 1000 && ~is_ptr_code(t)`, and a function-pointer type is
`2000 + return type` - over 1000, and not a pointer code - so every one of those copies
took the STRUCT branch and emitted the member's ADDRESS where its value was due
(`p = s.f;` became `movq &s, p`: silent, not an error). `is_struct_code()` knew the
difference all along and excluded pointers and function pointers; the hand-written
copies did not. All six ask it now, and a function pointer as a struct member parses,
loads, stores, sizes and calls - guard `cc57_fptrmember.c` (exit 96), which also covers
a nested member, an array of them, a global struct and `->`. Ceiling 22493 -> **22703**.

**A pointer to a row in all three declarator positions (2026-11-05).** `int (*p)[3]`
worked as a local (cc52) while two positions were refused, each with its own message:
`typedef int (*PA)[3]` and `struct S { int (*p)[3]; }`. Both are the type the variable
path has always built - `pcode(array_type(pcode(elem, depth), dims), 1)` - so both build
it the same way now, consuming the row's dimensions as the POINTEE's rather than as the
declaration's own array dimensions. Guard `cc58_ptrrow_forms.c` (exit 96) checks the
step rather than the declaration: after `p + 1`, `(*p)[0]` is the next row's first
element in every form, and `sizeof(PA)` is 8 while `sizeof(*p)` is 12. Ceiling
22703 -> **22884**.

The other four "not supported" messages in `cc_int.m` were each checked the same way and
are accurate: `(int[]){…}` compound literals work, `(int*){…}` ones do not (gcc agrees),
`%` on doubles is illegal C, and float literals in array initializers, `/=` on doubles
and `void` variables are real gaps with real messages. That is the point of checking:
after this session, the code's own claim of what it cannot do is measured, not assumed.

**`lvalue_addr` measured, and why it was not converted (2026-11-05).** It decides
"is this an lvalue?" by matching the instructions just emitted against a list of load
forms - a real design problem, but not the cause above: once the predicate was fixed the
member load was an ordinary `movq (%rax), %rax`, which the list has always accepted. The
measurement below stands on its own for the future.

Measured before editing, by instrumenting a shadow copy of `cc_int.m` (counters in each
branch of `lvalue_addr`, loaded ahead of `src` on the path) and compiling all 472 corpus
programs - 452 compile, 20 refused as intended:

    load=969   bitfield=37   address=31   row=14   none=3

`none` is the three intended lvalue errors. So four shapes are real, each needs
recording, and the split is dominated by the plain load while the other three are common
enough that any of them going unrecorded would be a real regression.

The conversion stops here, for a reason the measurement made concrete: there is no choke
point to record them at. `address` is recognised today as "the last instruction contained
`leaq`", and `leaq` is emitted at nine-plus separate sites (`&x`, struct values, string
literals, local and global addresses). A shape flag set at "the leaq emitter" has no
single place to live. What is needed is a small vocabulary: each producer of a value says
how it is currently represented in rax - a load, an address, an indexed row, a bit-field
extraction - and `lvalue_addr` reads that instead of guessing. The producers are
`em_val` (loads), the address forms, the index/row path, and `em_bf_extract`, which
already records its own description in `lbf`. Four producers, one consumer: a session's
work, not an afternoon's.

**The histogram is the acceptance test.** Rerun the same probe after the conversion; if
the four counts are unchanged and `instr` is still 22493, the conversion is
behaviour-neutral on 452 programs - a better promise than any assertion, and the reason
to do it properly rather than quickly.

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
the 729-check suite staying green.

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
interpreter's narrow-string convention — the compiler normalises `%ls`/`%hs` to
`%s` for that reason; integer length modifiers pass through since 2026-11-04
(see the printf entry below). Plus non-constant global initializers
(`int h = g + 2;`, `int h = f();`) evaluate in main's startup prologue.
The output-parity group grew from 6 to 53 programs (hello, p6_*, and 47
of the pp_* corpus); the 4 excluded are the intended-error tests and
`%p` (synthetic interpreter pointers vs real addresses — inherently
unmatchable).

**Optimization Phase B (peephole, 2026-08-16).** The first
optimization pass landed in `cc_int` (`peephole_pass`): it runs after
codegen to a fixed point and (1) drops `jmp .L` whose target is the very
next label (every function's final return jumps to its own epilogue —
the dominant win), (2) drops unreachable instructions after any
unconditional jump, (3) folds `movq $N, %rax; imulq $M, %rax` into
`movq $N*M, %rax` (constant-index array scaling), and (4) collapses
`jcc .L1; jmp .L2; .L1:` into the inverted condition straight to `.L2`.
Corpus instructions 8,697 → 8,271 (−4.9%); hello.c 106 → 103; the
729-check suite stays green and the regression ceilings were ratcheted.
Two clone quirks hit on the way: `strfind` rejects numeric arrays (use
`find(ln == 9)`) and a function parameter named like a caller global
(`out`) gets shadowed — lines are processed as double code vectors so
internal-name strings (`exit`, `sum`, …) are not mangled crossing
local-function boundaries (the x86sim sidestep).

**Optimization Phase C (address modes, 2026-08-16).** The peephole
pass grew three folds: `leaq K(%rbp), %rax; movq (%rax), %rax` →
`movq K(%rbp), %rax` (also movzbl/movsbl and the `name(%rip)` global
form), `movq $N, %rax; movq %rax, mem` → `movq $N, mem`, and
`leaq K(%rbp), %rax; addq $N, %rax` → `leaq K+N(%rbp), %rax`
(constant-index array addressing). The `leaq; pushq; …; popq %rbx; movq
%rax, (%rbx)` store pattern no longer occurs (the codegen emits direct
`movq %rax, K(%rbp)` stores). Corpus instructions 8,271 → 7,835,
`leaq` 837 → 481, hello.c 103 → 96; suite 729/729 green; ceilings
ratcheted. (One bug: `ao1(2:end-1)` is an empty slice on the two-char
`$8`.)

**Optimization Phase D (constant folds, 2026-08-16).** The setcc
normalize-then-branch chain (`cmpq A; setcc %al; movzbl %al, %eax;
cmpq $0, %rax; je/jne .L`) folds into a single branch on the original
compare — the chain's 0/1 value is consumed only by the branch (51
chains × 3 instructions = 153). `je` inverts the setcc condition,
`jne` keeps it; the unsigned setccs fold to `ja`/`jae`/`jb`/`jbe`,
which the x86sim did not support — the simulator grew those four
branches (the suite caught the gap). Constant-constant arithmetic
(`2 + 3`) measures zero occurrences in the corpus. Corpus instructions
7,835 → 7,686, hello.c 96 → 90; suite 729/729 green; ceilings
ratcheted.

**Optimization Phase E (stack traffic, 2026-08-16).** The operand
juggle folds: `pushq %rax; <simple right>; movq %rax, %rbx; popq %rax;
op %rbx, %rax` becomes `movq <right>, %rbx; op %rbx, %rax` (the left
survives in rax across a push), with the div/mod (`cqto; idivq %rbx`)
and shift (`movq %rax, %rcx; shlq %cl, %rax`) tails. A small
register-allocation fold keeps the store-LHS address in r8
(`pushq %rax; <rhs>; popq %rbx; movq %rax, (%rbx)` →
`movq %rax, %r8; <rhs>; movq %rax, (%r8)`), guarded by a call/push/
store/r8 barrier — nested assignments (`y = x = 10`) required the r8
guard and were caught by the suite. A hidden bug was found and fixed:
every foldmap replacement was missing its leading tab, so folded lines
were invisible to the next pass iteration — the fix unlocked cascading
composition. Also: the clone's `strfind` rejects numeric code vectors,
so a manual `pp_contains` substring helper replaced it (the `name(%rip)`
folds had been silently dead). Corpus instructions 7,686 → 6,184,
`pushq` 2,391 → 571, hello.c 90 → 73; suite 729/729 green; ceilings
ratcheted.

**Optimization Phase F (clarity, 2026-08-16).** The optimizer moved
out of the compiler: `peephole_pass` and its 14 helpers now live in
`src/peephole_pass.m` (496 lines), called by `cc_int` after codegen —
making the pass directly unit-testable. A suite group (`ppunit`, 11
checks) feeds one synthetic fixture per fold rule and asserts each
rewrite fires, plus the nested-assignment guard, so no rule can silently
regress. `cc_int`'s header documents the full pipeline (tokenizer →
parser → codegen → peephole_pass). Suite 729 → 740, all green; the
refactor is behavior-neutral.

**Optimizer complete (2026-08-16).** The optimization effort (plan
`docs/2026-08-16-compiler-optimization-plan.md`, phases A–F) is done:
`peephole_pass` in its own file rewrites the emitted assembly to a fixed
point, and the compiler corpus dropped from 8,697 to 6,184 emitted
instructions (−29%), `pushq`/`popq` from 2,391 to 571 (−76%), hello.c
from 106 to 73 — the 740-check suite green at every phase (gcc exit
codes, gcc-free x86sim exits and stdout, output parity, an
instruction-count regression that ratchets the ceilings, and per-rule
unit fixtures). The README now documents the optimizer in its own
section.

**Stress program + two real bugs found (2026-08-16).** A ~200-line
`tests/programs/stress.c` (string library, sort/search, 3×3 matrix
multiply, recursion, primes, popcount — 5467 checksum) now runs through
all three tracks in the suite (gcc exit 91, x86sim 91, interpreter
5467 mod 256, stdout parity). Writing it found two real bugs:

1. **Clone bug (fixed in the clone source, needs a release rebuild):**
   `interpreter.c:2959` concatenated MATLAB `['a' 'b']` strings into a
   fixed `char buf[4096]` — the compiler's output-join overflowed it at
   ~34 statements (valgrind: `__strcat_chk` abort). The fix grows the
   buffer; verified under WSL valgrind (0 errors) and on Windows. The
   user's `release/v1.3.21` still has the old binary until rebuilt. —
   **rebuilt 2026-08-17**: `build_gcc.bat` → `matlab.exe` copied over
   the release binary (old one kept as `matlab.exe.bak`); the full
   744-check suite passes against the official `matlab.bat`, and the
   temporary `t_fixed/` binary was removed.
2. **x86sim bug (fixed here):** `movzbl`/`movsbl` loaded 8 bytes and
   masked — for a byte inside a string whose following bytes are
   nonzero, the 8-byte value exceeds 2^53 and the double conversion
   loses the low byte (stress's `strlen("hello, stress!")` = 0). The
   sim now reads a single byte (`sim_byteval`). The corpus never hit
   this (char loads were always from small-value arrays).

Suite 740 → 744 (stress in the gcc/x86sim/parity/output-parity groups;
the instruction-count baseline rose to 7387 with stress included).

**Second stress program + one more sim fix (2026-08-17).**
`tests/programs/stress2.c` (~450 lines: string library, five sorts
(bubble/insertion/selection/quicksort/mergesort) + searches, 3×3
matrix algebra, number theory (gcd/lcm/factorial/fib/powmod/divisors/
totient/prime sieve), bit tricks, string analysis, a parallel-array
database — checksum 988156804) runs through all three tracks and is
registered in the suite (gcc exit 132, x86sim 132, interpreter parity,
stdout parity). Writing it found:

- **x86sim `%d` formatting bug (fixed here):** `fmt_int` used
  `num2str(v, '%.0f')` — the clone ignores the format and prints %g, so
  values past ~1e5 came out scientific (`9.8765e+08`). The corpus never
  printed values that large. Fixed with a manual `sim_decstr`.
- **compiler dialect note:** `cc_int` had no hex literals (`0xAAAA` was a
  parse error) — stress2 used the decimal value. Closed 2026-09-19; see
  the hex entry below.

Suite 744 → 748; the instruction-count baseline rose to 10,898 with
stress2 included.

**One more fold (2026-08-17).** An audit of the remaining corpus
found 173 dead `subq $0, %rsp` instructions — the frame allocation of
functions with no locals (missed in Phase B, which only checked the
value-register forms). The peephole now drops them (rule 10, with a
ppunit fixture). Corpus 6,177 → 6,004 (−173); hello.c 73 → 72; suite
749/749. The remaining irreducible items: prologue `pushq %rbp` (342),
call-arg pushes + param loads (~200 — would need a register-arg calling
convention), and store-spills whose RHS calls a shim (73).

**2026-08-18 fix round (suite 749 → 764, all green).** A full review of
the codebase (four parallel reviewers, every finding empirically
cross-checked) produced one round of fixes:

- **cc_int**: backslash escapes in string literals now survive to the
  `.string` data — `strtext` became a DOUBLE code vector (the clone
  mangles backslash-bearing char strings crossing globals, which had
  silently eaten `"a\\b"` → `"ab"`), and the emission escapes `\\`, `\"`,
  and `\n` numerically; `unsigned >>=` now emits `shrq` (it used to
  always emit `sarq`); forward calls validate their arg counts after the
  parse completes (`called` accumulates per-call-site counts — before,
  only already-parsed callees were checked).
- **x86sim**: `mem` now covers `[0, CODE_BASE + code length + slack)`
  (the stack used to live past the array end — out-of-bounds reads/writes
  the clone tolerated; real MATLAB would error); CF from the full 64-bit
  borrow (unsigned comparisons of values ≥ 2^32 were wrong); `%X` prints
  uppercase (the conversion was an arithmetic no-op); `%05d` puts zeros
  between the sign and the digits (`"000-7"` → `"-0007"`); `testb` sets SF
  from bit 7; dead code removed.
- **xc**: nested-brace array initializers enforce the same too-many guard
  as flat ones (`{{1,2,3},{4,5,6},{7,8,9}}` on `int[2][3]` used to
  overflow the array silently); global constant-expression initializers
  (`int x = 1 + 2;`) evaluate at compile time via a full-precedence
  constant evaluator (the cryptic `bad global declaration` is gone); the
  lvalue checks for `&`, assignment, and pre/post-increment use a new
  parse-level `unit_was_lvalue` flag — the old check read the emitted
  load slot, which COLLIDES with IMM operand values 9/10 (the LI/LC
  opcode numbers), so `&(9)`, `&(10)`, and `(9) = 5` were silently
  accepted as fake lvalues.
- **peephole**: rule 9's shift tail puts byte-width shift counts in
  `%ecx` (it emitted `movzbl RO, %rcx` — invalid AT&T); the rule-10
  barrier's depth counter only counts `addq $imm, %rsp` (a rhs `addq`
  used to hide the r8 store-spill fold); the header now lists the
  store-spill as rule 10 and the empty-frame fold as rule 11.
- **harness**: the gcc-free groups (x86sim corpus, output parity, the
  instruction-count regression, ppunit fixtures, error checks) moved OUT
  of the gcc gate — a gcc-less machine previously lost ~600 checks
  including the gcc-free track; the compiled exe is invoked as
  `.\tmp_cc.exe` (cmd's CWD-relative lookup breaks under
  `NoDefaultCurrentDirectoryInExePath`); new ppunit fixtures cover the
  shift tails (byte/word), the store-spill-with-addq rhs, and the
  nested-guard fixture now asserts the r8 rewrite it claims to guard.
- New corpus: `cc18_strbslash.c` (92), `cc18_ushr.c` (0), `cc18_ucmp.c`
  (1), `cc18_printfX.c` (0), `cc18_printf05.c` (0), `pp_globalcexpr.c`
  (3), plus the intended-error programs `pp_badnestedinit.c`,
  `pp_badaddrof2.c`, `pp_badassign.c`, `cc9_badargs2.c`, and two direct
  x86sim stdout checks (`%X`, `%05d`). Instruction-count baseline
  10,715 → 10,822 with the new programs. Verified end-to-end on the
  v1.3.25 release build.

**Double support (2026-08-19).** `cc_int` and `x86sim` gained a
floating-point value model end to end: `double` literals/locals/params
and their arithmetic, comparisons and casts emit and execute SSE
instructions, and the simulator carries an `xmm` register file. A
gcc-parity double corpus plus `tests/run_double_regression.sh` guard it.

**MEX/mx layer + the gcc reference oracle (2026-08-20 → 2026-08-26).**
The compiler grew an in-memory `mxArray` ABI with `mx*`/`mex*` stubs
inside `x86sim` and a driver, `mex_run`, that assembles `mx_preamble` +
a MEX source + a synthetic `main`, compiles it with `cc_int` and runs it
in the simulator — MEX code executes with no external C compiler.
`mex_run(..., 'gcc')` compiles the SAME source with real gcc and the two
are diffed, so the simulator is checked against a compiler-independent
oracle rather than a hand-written expectation (`tests/run_mex_run_gcc.sh`
and the mx/matfile/`strncpy` gates hold the corpus, 20/20 A/B). Along the
way `cc_int` gained C block scoping (sibling blocks may reuse names),
`static` functions, enum case labels, `mxClassID`/width typedefs, and
`x86sim` exact 4-byte `movl` loads and 8-byte char/logical slots;
mex-mode pass 1 was made ~100x faster.

**x86sim Bug A/B + no-operand dispatch (2026-09-06 → 09-08).** Dense
`double` literals and high-precision `%.17g` printf were fixed
(`5c31063`), as was a `.quad`/`.long` numeric global that stored only its
low byte (`6228ea1`), each with regression corpus and direct sim checks
(`3b9c466`). `1fd742b` maps no-operand instructions to their mnemonic so
`ret` no longer mis-dispatches; `6b84eda` removed dead code and
superseded plan docs.

**Correctness round (2026-09-08 → 09-19).** An unsigned shift whose
count is a raw int64 register (`shrq %cl`) did the division with
round-half semantics only on the clones; the count is now forced double
(`6a73590`). `parse_statement`'s label-peek read `token_val` without
declaring it global (`7db5dfe`), and a static audit then found 19 more
references to file-globals that functions did not declare (`5ed841d`) —
legal only under the clones' caller-chained scoping, an error under real
MATLAB's isolated function scopes. That audit is now a permanent guard,
`tests/check_globals.m`, run over every `src/*.m` with its own self-test
(`4d07835`). The dense-`%.17g` guard's gold string was missing the
program's trailing newline (`b5af653`), and with gcc present the
expectation is now gcc's own stdout rather than a hand-copied string
(`4d07835`). `run_tests` appends every check to `run_tests.log`
(`5036aca`) so a run killed by a host suspend still leaves its record.

**Hex literals + full green (2026-09-19).** `cc_int` now lexes C90
hexadecimal integer constants (`0x`/`0X` + hex digits) in every constant
context — expressions, global initializers, array sizes and initializers,
enum values — accumulated with `bitshift`/`bitor` so full-width values
wrap mod 2^64 like C rather than saturating (`0xFFFFFFFFFFFFFFFF` is `-1`
as a bit pattern); a bare `0x` errors. Integer suffixes (`0xFFu`) remain
unsupported, as they already were for decimals. `tests/programs/cc19_hex.c`
(exit 76, gcc-verified) joins the gcc exit-code, x86sim corpus and
cross-track parity groups; the instruction ceiling was re-baselined to
10938. The suite is **777/777** on v1.3.72.

**Octal miscompile fixed + literal-forms corpus (2026-09-19).** A
leading-zero integer was read as decimal, so `0777 & 0xFF` compiled to
`777 & 0xFF` = 9 instead of octal `511 & 255` = 255 — a silent wrong-code
miscompile (gcc and the interpreter both gave 255). The lexer now reads
`0[0-7]+` as base 8, rejects 8/9 with gcc's `invalid digit in octal
literal`, and wraps full-width values mod 2^64 like hex. Because the
corpus had no octal (nor, before cc19, hex) literal, the bug survived;
two guard programs now cover the bases: `cc20_litforms.c`
(decimal/hex/octal in expressions, a global, an array size and an enum;
exit 104 on gcc, x86sim and parity) and `cc20_litwide.c` (full-width
hex/octal wrap to the all-ones pattern; compiler track only, exit 7).
Ceiling 10938 → 11047; suite **780/780**.

**Width-type locals, casts and sizeof (2026-09-19).** `parse_basetype` had
long accepted `short` (2-byte), `word` (4-byte) and `long` (8-byte then;
4 since the 2026-11-04 round), but
the places that decide "is this a type?" — `parse_statement`'s declaration
dispatch, `parse_for`'s init, `is_cast` and `sizeof(type)` — omitted
tokens 193/194/195, so `short s = 3;` failed while globals of those types
worked. All four now accept them (`is_cast`/`sizeof` also gained
`unsigned`). Two related bugs fell out: `sizeof(short)` returned 8 (the
narrow bases had no size mapping; now 1/2/4/8 for char/short/word/int)
and a cast to short/word did not truncate (`(short)0x10003` stayed 65539;
now masked to 16/32 bits). Guards: `cc21_width.c` (exit 173, gcc + x86sim)
and the simulator-only `cc21_wordloc.c` (`word` is a cc_int extension, not
C). Ceiling 11047 → 11148; suite **782/782**.

**Escape sequences + integer suffixes (2026-09-19).** Only `\n` was
decoded in char and string literals; every other escape dropped the
backslash and kept the next character, so `'\t'` was 116 and `"\t"`
printed `t` — silent wrong data on both tracks (gcc's 153 came out 409).
The new `src/c_unescape.m` owns the table (simple escapes, octal `\NNN`,
hex `\xNN`, unknown keeps the character) and both lexers call it.
Integer constant suffixes (`5u`, `0xFFu`, `10L`, `7UL`, `3llu`) are also
accepted now — previously the lexer stopped at the digits and failed on
the trailing identifier — via a shared-shape `lex_suffix()`; the value is
unchanged since width and unsignedness come from the declared type.
Guards: `cc22_escapes.c` (exit 27; char values via the exit code, string
bytes via stdout, in the gcc/parity/output-parity groups) and
`cc23_suffix.c` (exit 72, gcc + parity). `cc24_wide.c` (exit 96,
compiler-track only) closes the 64-bit decimal literals above 2^53 —
emission, the immediate parse, the 64-bit store and `%ld` are all exact in
int64 now, and the peephole no longer folds a full-width immediate into
memory. `cc25_fmt.c` (exit 96) closes `%u`/`%x`/`%X`/`%o` (and `%p`) for
the full unsigned 64-bit pattern. Ceiling 11148 → 11312 → 11402 →
11459 → 11673 → 14072 → 14150 → **14448**; suite **802/802**.

**Signed/unsigned narrow types (2026-09-29).** The width model zero-extended
every narrow type, so a signed `char`/`short` lost its sign on widening —
`short s = -1; int i = s;` was 65535 (gcc: -1) and `char c = -1; int j = c;`
was 255 — and `unsigned short`/`unsigned long`/`unsigned char`/
`unsigned word`, `long long` and `signed` did not parse at all.
`parse_basetype` accepts the full specifier set now (any order, plus
`long long`; `signed` is a new keyword and the default signedness), the
unsigned narrow forms get base codes 12/13/16, and a single `em_val()`
helper widens every typed load with the sign the type calls for (signed →
`movsbq`/`movswq`/`movslq`, unsigned → zero-extend); the cast and return
paths follow and `sizeof`/`elem_size` cover the new codes. The simulator
gained those three sign-extending mnemonics. Guards: `cc26_signed.c`
(exit 96, gcc-comparable) and the sim-only `cc26_word.c`.

**`int` is 32-bit (2026-09-29).** The compiler modelled `int`/`unsigned int`
as 8 bytes with `long` reusing the same base, so `sizeof(int)` was 8,
`int y = INT_MAX; y += 1` did not wrap, int-pointer strides were 8 and
`long` arithmetic was scaled as a pointer (`l = l + 1` added 8). `long`/
`unsigned long` now have their own 8-byte base codes (17/20) and `int`/
`unsigned int` are 4 bytes. A single `tsize()` width table drives
`em_val`/`em_store`, the cast/return paths, `sizeof`, struct member layout,
array/global strides, the global initializer directives (x86sim gained
`.short`/`.long`) and the local/compound-literal initializers; `is_ptr_code`
replaces the old `t >= 2` pointer tests (which also fixes `short s; s++`,
previously +8). Intermediate int arithmetic became 32-bit when the narrowing pass
 landed (it was 64-bit at the time of this entry). Struct alignment is per-member (2026-11-03: a member sits at the next
multiple of its own alignment and the size rounds up to the widest member's,
so `sizeof` matches gcc; `ssize_slot` keeps the storage a whole number of
words for the copy loops). Intermediate int arithmetic is 32-bit with C's wraparound (the narrowing pass in the 2026-10-02 commit; measured: `a=0x40000000; a*4`, `b=65536; b*b` and `(long)(b*b)` all agree with gcc). Guard `cc27_int.c`
(exit 96, gcc-comparable); ceiling 11673 → **14072**, hello.c 72 → 84.

Interpreter divergence: `xc`'s VM word is 8 bytes (`sizeof(int)` = 8), its
own model (a port artifact of xc.c's int-word VM); `cc13_si1.c`/`cc13_si5.c`
left the cross-track parity list for that reason.

**Six dialect items (2026-10-02).** From the feature sweep, in order:
`enum Tag` is a type (the tag names an int; a non-consuming peek separates a
definition from a tag reference); local struct aggregate initializers
(positional, nested braces, `.name = v`, C zero-fill); array members (they
decay to a pointer, take a nested initializer, and `sizeof` sees the array);
`char s[] = "abc"` takes its size from the string (NUL included, escapes one
byte); `static` locals persist (they live in the data section, not the
frame); and the function-pointer call path counts pushed words, not
arguments (the same defect fixed on the direct path). Guards
`cc33_enum.c` … `cc38_funptr.c`; suite 810/810; ceiling 14810 → **15819**.

**One initializer parser, and the leaf numbering has one owner
(2026-10-02).** The aggregate-initializer grammar was implemented twice - once
emitting frame stores, once producing leaf values - and the copies had drifted
three times. They are one now: `aggregate_values` reads any aggregate into a
flat leaf vector, `struct_bytes` lays that vector out, and `em_bytes` stores
the image into the frame, so the frame and the data section cannot disagree.
`struct_fill`, `fill_member` and `parse_struct_init` are gone.

The bug that held it up was a **pass-through variable**: `vi`, a leaf cursor
threaded through the layout recursion as an in/out parameter, counted
independently of the parser's own count. Making `member_leaf_offset` the single
owner of "where does this member's leaves start" removed the cursor entirely,
and the two can no longer drift by one. Guards `cc45` (array of struct values)
and `cc46` (the three shapes the two parsers disagreed on) pass. Ceiling
17947 -> **18235**.

**Struct alignment matches gcc (2026-11-03).** `sizeof` was 8-byte coarse: `{int,int}` was 16 where gcc says 8, `{char,int}` 16 where gcc says 8. It is now C's rule: a member sits at the next multiple of its own alignment (`align_of`: its width capped at 8; a struct member uses that struct's own maximum) and the size rounds up to the widest member's. Introduced in two commits, deliberately: first `ssize_slot` (the *storage* size - a frame slot, parameter area, return slot, every copy) as a proven no-op, because seven copy loops assume whole 8-byte words and the old coarse layout had been hiding that; then the layout switch itself. `ssize_of` stays C's size (sizeof, offsets, strides, the data image). Guard: a layout probe comparing sizeof, member gaps and array strides against gcc on six structs - all match. Verified: 12/12 aggregate guards x gcc/simulator x C clone/Rust engine (16 combinations), tables 245/245, instr 142/142, corpus 655/655, ceiling 18235 -> **18120** (smaller structs).

**The aggregate-initializer family (2026-10-02).** Five items, one commit
each: C's brace elision (`{1,2,3}` meaning `{{1,2},3}`); multi-dimensional
array members (`int m[2][3]`, with the stride table); `char g[] = "abc";` at
file scope; designated `.name = v` for file-scope structs (which also
exposed two pre-existing bugs: `place_members` recursed into a nested struct
without adding its offset, and a global initializer put every element of an
array member on the member's first slot); and `enum { A } v;` at both
scopes plus a per-function symbol for static locals, so two functions may
each have a `static int n`. Guards `cc40`-`cc44`. Suite 816/816; ceiling
16704 → **17764**.

**`mx_preamble` is one row everywhere (2026-10-02).** The declaration
block carried a comment-only block inside its `[...]` literal, and a
newline inside brackets starts a new row: the preamble was a 1x843 row on
the Oct-2 clone but a **2x758 matrix** on the release build and the Rust
engine (and in real MATLAB), so `fprintf('%s', pd)` wrote it column-wise and
the compiler said "expected a type" - the mx gates passed on one runtime
only. The notes moved above `txt = [` (where they cannot change the shape),
and the block is now `1x843` with identical content on all three runtimes;
the release build runs mx smoke 6/6, mex_run smoke 6/6 and the gcc
cross-track gate **20/20**, so one stable runtime covers every gate.

**32-bit intermediate arithmetic (2026-10-02).** Expression temporaries
were 64-bit, so C's wraparound did not happen: `(long)(x*x)` for x = 50000
gave 2500000000 where gcc gives -1794967296, and an `int` product could stay
positive past 2^31. The operators now apply the usual arithmetic conversions
(`int_promote`/`int_width`/`arith_type`) and narrow the result to that type
(`em_narrow`), so an int result is `movslq`-ed to 32 bits, an unsigned one
zero-extended, and a `long` left alone. The same pass found that
**integer-literal suffixes were lexed but discarded** - `1L << 40` was a
32-bit shift that came out 0 - so `lex_suffix` records the suffix in
`token_sfx` and `num_type` gives the literal its type (int, or long long when
it does not fit; `LL` was added on 2026-11-04, when `L` became a 32-bit long
to match the ABI). `volatile` is accepted as a no-op qualifier too. Guard
`cc39_wrap.c` (exit 96). Suite 811/811; hello.c 84 -> 88 instructions,
ceiling 15819 -> **16704**.

**Pointer codes no longer collide (2026-10-02).** Pointer types were
`base + 2*depth`, which landed on value codes: `char **` came out as 5 =
`unsigned int`, `short *` as 9 = signed word, `int **` as 4 = void - so
`is_ptr_code` had to guess. They now live in their own band,
`pcode(base, depth) = 4000 + base*64 + depth`, with `pbase`/`pdepth`/
`pdecay`/`pderef`/`padd` helpers (depth in the low bits keeps address-of and
dereference a single step). `is_ptr_code` is simply `t >= 4000`. The
knock-on edits: every `t >= 1000` "is it a struct?" test now also excludes
the pointer band, `is_fptr_type` is bounded below 4000, `elem_size` sizes a
pointer element as 8, and array decay goes through `padd` so an array of
pointers (`const mxArray *prhs[]`) is right. `char **dir = matGetDir(...)`
now compiles and runs: the mx cross-track gate is back to **20/20**.

A follow-up the suite caught: `typedef int *ip;` puts a *pointer* code in the
`base`, where every `base >= 1000` test read it as a struct value
(`ssize_of(4001)` - an index error in `cc30_typedef.c`). Those 15 tests now
go through `is_struct_code`, which excludes the pointer band and the
function-pointer space. Verified: suite **810/810**, all four gates, and the
32-program differential. The ceiling is unchanged at 15819 - an earlier
15674 was measured while `cc30_typedef` failed to compile.

**Known gap found while checking the gate:** `char **d; d[0]` fails with
"pointer type expected for indexing". `char **` is type code 5
(`1 + 2*2`), which is also the `unsigned int` code, and `is_ptr_code`
excludes it - so a doubly-indirected char is not a pointer. Three revisions,
including the one that scored 20/20, fail identically, so this is
pre-existing, not a regression. It is why the mx cross-track gate is now
17-18/20: `matfile`/`matfile_del` declare `char **dir = matGetDir(...)`.

**Struct-by-value arguments, and the call cleanup (2026-10-02).** An
empirical sweep (32 small C programs, gcc vs ours) found passing a struct by
value gave field-reversed values: the caller pushed the copy low-address
first, so `pushq`'s downward growth put member 0 highest. It now pushes the
highest address first. The same sweep exposed a second, sharper bug — the
call cleanup popped `8 * nargs` while counting each argument as one word, so
a multi-word (struct) argument left `%rsp` high and the caller's frame
garbage. `pwords` now tracks the words pushed. Note the two oracles
disagreed: x86sim returned 96, the gcc-assembled cctests path returned **5**
— the simulator does not model `%rsp` drift, the real CPU does.
`cc32_byval.c` runs through the cctests path so that class now fails the
suite. Ceiling 14810.

**The suite runs on real MATLAB: what failed there, and why (2026-11-04).** A
full `run_tests` on R2024b passes the interpreter track wholesale - both
selftests, every p3/p4/p5/p6 and pp_* program - and about three hundred compiler
corpus programs, the gcc-free x86sim corpus **325/325**, and every guard from
cc31 to cc51. The failures it does report fall into three classes, and two are
fixed:

1. **Exit statuses were not reduced mod 256** (about ten checks). The OS reports
   only the low byte; real MATLAB's `system()` hands back the FULL status - 300
   for `exit(300)`, 5467 for `exit(5467)`, 988156804 for stress2 - while both
   clones truncate. Every "wrong" value was the expected one plus a multiple of
   256 (5467 mod 256 = 91, 988156804 mod 256 = 132, 321 mod 256 = 65). The
   harness takes `mod(got, 256)` now, which also maps -1 (exit 255) to 255 the
   way the old `+256` did.
2. **Synthetic names were not valid MATLAB field names.** Anonymous structs were
   tagged `@anon3` and per-function statics `__st1_n`, and both are used as
   STRUCT FIELD names (`membermap.('@anon3')`, `globals.('__st1_n')`). MATLAB
   requires a field name to begin with a letter, so `cc29_union`, `cc30_typedef`,
   `cc37_static` and `cc44_enumstatic` failed outright on the target - and their
   parity, x86sim and union/typedef checks with them. They are `anonstruct3` and
   `fnstatic1_n` now; the emitted symbols change name, not shape (instruction
   total still 21498).
3. **About fifty "stdout mismatches" were not mismatches.** With the harness
   printing both sides, the failing checks read `xc 0 chars, cc_int 0 chars` and
   still compared FALSE. Two empty captures, unequal - so the two sides were not
   the same TYPE, and an empty capture does not come back as the same thing a
   non-empty one does on that runtime. That accounts for the split exactly: every
   failing check was a program that prints nothing (`pp_addrof`, `pp_array*`,
   `pp_arrinit*`, `pp_sizeof*`, `pp_mdim*`, `pp_init*`, `pp_void*`), every passing
   one printed something (`pp_s`, `pp_prtflen`, `pp_npercent`, `pp_dynwidth`,
   `stress`, `stress2`, `hello`, `p6_printf*`). `same_text` puts both sides through
   `char` first, so the comparison no longer depends on which type an empty capture
   has - which is also why it could never be reproduced on the clones: they return
   the same type either way.

**The runtime is matlab_in_rust's engine (2026-11-05).** `tests/env.sh` resolves to
`matlab_in_rust/dist/matlab-cli/matlab.exe` - currently `cli-v21-5-g9dc5345`,
21,165,023 bytes, 2026-11-14 22:43 - when `MATLAB` is not exported. The pin here is
the binary that is INSTALLED, and it is worth re-reading rather than assuming: it sat
at `cli-v18` for two days while `cli-v19` and `cli-v20` were tagged, and assembling
`call exit` was measured against a copy two days older than the fix for the defect it
found. The three runtimes have three roles
and it matters which is which:

- **the engine** (`cli-v21`) is the runtime this project runs on. It is MATLAB
  *enough*: every check in this suite passes on it, at the cost of compile throughput
  ~270x the C clone and superlinear in source size, which is why the suite is sliced
  by section and by program range rather than run whole.
- **real MATLAB (R2024b)** is the authority when the two disagree, and it has
  disagreed: the full-precision exit status, the invalid struct field names
  (`@anon3`, `__st1_n`) and the empty-capture type were all invisible on both copies.
- **the C clone** (`MATLAB_in_C/release/v1.3.86`) is the ORACLE for cross-checks - it
  is what most engine bug reports were measured against - not a runtime to run the
  suite on.

`env.sh` now probes whatever it resolved (`getenv`, plus running a script file) and
fails at startup naming the path. Before that it silently fell back to a 1.86 MB
build in `MATLAB_in_C`'s root that has no `getenv`, so a clone with nothing exported
died inside the harness with `Unrecognized function or variable 'getenv'` - and, with
the new verdict classifier, was then reported as "the host kills it at a random
point". `run_all.sh` prints the runtime and its size/date before the suite, because a
log that does not say which engine produced it cannot be compared with another.

Six engine defects were found from here and all are fixed by `cli-v21`: `%0NX` hex
padding, `sprintf` repeating its format for string args, `x(:)` on a char row,
`strcmp(cell,char)` returning a scalar 0, `sprintf('%s', ["ab","cd"])` throwing, and
`c{end+1} = []` being a silent no-op - the last one the one that would have corrupted
a compiler table - and indexing a char array whose value is `exit` or `quit`
terminating the interpreter (found from `call exit` in a corpus program; fixed at
`b648ecb`, and the two-line reproducer is in `matlab_in_rust/docs/`). Their reports
live in `matlab_in_rust/docs/`.

**A cut-short run is now distinguishable from a failing one (2026-11-05).** This
host kills `run_tests.m` at a random point - three deaths were observed in one
session, at check 216, after `cc29_union`, and after `stress2` - and every rerun of
the identical command was green. Measured: the killed process returns exit **1**,
the same code a failing run returns, and nothing in-process can report it, because
no MATLAB code runs after the kill (an in-process `try`/`catch` guard was written,
tested against synthetic suites, and then deleted for that reason). The evidence
that survives is a file: the harness writes `run_tests.verdict` ("<passed> <failed>")
as its last act and deletes it on startup, so `run_all.sh` reads *that* instead of the
exit code - file present and 0 failed = pass, present with failures = failed, absent =
cut short, retried once since the death is random. Parsing the printed summary line
was the first attempt and it was wrong in a way worth recording: the wording of a
human-facing message became a contract between two files, and rewording it turned a
green run into a reported failure. Measured on a reworded log, which the old
classifier called "failed".
A boot failure - an unrecognised function before the first check - classifies as cut
short too, which is why the log path is printed with the verdict.

**Green on real MATLAB (2026-11-05, final): 832 tests, 832 passed, 0 failed, no
warnings.** The run that measures the last two features: `cc58_ptrrow_forms.c` passes at
exit 96, so a pointer to a row is right in all three declarator positions (local,
typedef, member) on the authority runtime, and `&x = 5` is still refused there.
x86sim **336/336**, gcc stdout **333/333 byte-identical**, instr **22884**. 831 -> 832 is
cc58, which is what the count should do.

That closes the queue: every check the suite contains has now passed on the runtime this
project is developed against, and the three runtimes agree on all of it. What is left is
deliberate, and written down where the next session will read it - `lvalue_addr`'s
instruction matching (maintainability, no defect behind it), and four "not supported"
messages that were each measured and are accurate.

**Green on real MATLAB again (2026-11-05): 831 tests, 831 passed, 0 failed, no
warnings.** This is the run that measures the day's last three changes on the
authority runtime, and each one had a specific thing to prove:

- **function-pointer members** - `cc57_fptrmember.c` passes at exit 96, so the
  `is_struct_code` predicate (six hand-written copies of it replaced) is right on
  R2024b as well as on both clones.
- **`&x = 5` refused** - the new negative check passes, so the narrowing of
  `lvalue_addr` holds on the runtime that has contradicted us three times before.
- **`del()` is silent about a held file** - zero warnings in the whole run. That fix
  could not be proven on the clones, which never emit the warning; this is the
  evidence, and it is the only evidence that could have existed.

Also unchanged where it should be: x86sim **335/335**, gcc stdout **332/332
byte-identical**, instr **22703**. 829 -> 831 is `cc57` plus the two negative checks,
which is what the count should do.

**Green on real MATLAB (2026-11-05): 829 tests, 829 passed, 0 failed.** The run
that measures everything since the engine became the runtime: `probe_primitives`
38/38, both selftests, the p3-p6 interpreter track, every `pp_*` program, the corpus
through `cc56` - including the five guards that had never executed on R2024b
(`cc52`/`cc53` pointer-to-row, `cc54` tag scope, `cc55` multi-declarator typedef,
`cc56` function-pointer typedef), all at exit 96 - x86sim **334/334**, gcc stdout
**331/331 byte-identical**, and instr **22493**. 824 -> 829 is exactly the five new
guards, which is the arithmetic one wants from a count.

One warning survived it, in `del()`: `tmp_cc.exe` held by the previous program's
process reads on Windows as "file not found or permission denied", so the helper that
promises to be silent was silent about a missing file and loud about a held one. It
now probes the file for writing before deleting, which is the real condition - a held
file cannot be deleted anyway, and the corpus loop already retries for that reason.

**Green on real MATLAB (2026-11-04): 824 tests, 824 passed, 0 failed.** After those
three fixes a full `run_tests` on R2024b reports no failures at all: both selftests, the p3-p6 interpreter track, every
`pp_*` program, the compiler corpus through cc51, the x86sim corpus **329/329**,
and all 56 checks in *each* of the two stdout-parity groups. The scratch-file
warnings that used to bury the summary line are gone too: a bare `delete()` warns
when the file was never created, so it fired on every iteration wherever a step
had failed - `del()` checks `exist` first and all 31 call sites use it.

**The suite runs on real MATLAB too - and the harness was what broke
(2026-11-04).** `>> addpath('tests'); run_tests` on R2024b got through
`probe_primitives` 38/38, both selftests (30 VM cases, 9 lexer cases), and every
p3/p4/p5/p6/pp corpus check - several hundred PASS lines - and then stopped in
the HARNESS itself:

    vertcat: Dimensions of arrays being concatenated are not consistent
    run_tests, line 788:  pshared = {

The cause is a MATLAB rule the clones do not enforce: **a newline inside a cell
literal ends the ROW**. `pshared` listed five or six names per line, so it built a
ragged matrix instead of a list - 38 rows of 5-6 entries, with shorter rows at the
end - and MATLAB refuses to concatenate rows of different widths. The Rust engine
pads the rows instead (it builds a 38x6 cell and carries on), which is why nothing
here had ever noticed. Every OTHER literal in the harness is rectangular by
construction (`cctests` two columns, `stests` three, `ostests` one), so this was
the only one that could fail, and a static count of entries per row confirmed it.

`pshared` is now one name per line - a column, which is what its only reader
(`isin`, which walks `numel`) expects anyway. `tests/probe_literals.m` builds that
literal on its own and prints its shape, so the failing machine can confirm the
fix without `eval`: 191x1 here on both runtimes.

**It runs on real MATLAB (2026-11-04).** First execution of this compiler on
MathWorks MATLAB - R2024b 24.2.0.2806996, PCWIN64, on another machine - and
`tests/probe_matlab_portability.m` passes **7/7**:

- the four language rules the code leans on: a function reading an undeclared
  global IS an error (so `check_globals` guards something real), empty cell
  appends grow, `bitshift` on int64 wraps while `int64` addition saturates;
- three corpus programs compiled by `cc_int` and *executed* under `x86sim` to the
  clones' exit codes: `hello.c` (122 lines of assembly), `cc39_wrap.c` and
  `cc51_mdimparam.c` - the last being the newest code in the tree, array types
  and two-dimensional parameters.

Two INFO lines are runtime properties rather than faults: `fopen 'r'` does not
translate CRLF there (so `run_out` strips CRs itself), and `sprintf('%d', int64)`
is exact there where both clones round past 2^53.

Getting there took two real bugs, both invisible to gcc and to both clones:

- `run_out` had stopped stripping CRs because the clones translate text-mode
  reads; real MATLAB does not, so the harness would have compared CR-terminated
  text against clean text there.
- `parse_unary`'s `if at == 6 || dt == 6` had an EMPTY operand. `dt` holds a call
  argument's declared type and is `[]` for every variadic argument - i.e. every
  printf - and `[] == 6` is empty, which MATLAB rejects inside `||` and the clones
  read as false. It stopped every compile on the target.

The previous thirty-odd rounds were measured against gcc and two clones: a second
implementation of C, which is a good oracle for the dialect and no oracle at all
for MATLAB-host behaviour. One run on the real thing found what neither could.

**Pointers to arrays: the last limitation, and how it was closed (2026-11-04).** `&a` on an
`int[3]` is an `int (*)[3]`, and the type model had no way to say that - a
pointer was `pcode(elem, depth)` and nothing else - so `&a + 1` stepped 4 bytes
where C steps 12, and `int (*p)[3]` did not parse.

Array types are now a first-class type: `array_type(elem, dims)` interns a shape
into the free 3000..3999 band (`is_struct_code` had to stop claiming it), and a
pointer to one is an ordinary pointer code whose *pointee* is the array, so
`elem_size` - the one function that decides what `+ 1` steps - answers with the
whole row because `tsize` of an array type is its byte size.

With that, three things follow:

- **`&a` carries the array it points at.** The shape is recoverable from what the
  value already carried (total bytes and per-level strides: dims(1) =
  bytes/stride1, dims(k) = stride(k-1)/stride(k)), so `&a + 1` steps 12, `&a[0]`
  on a 2-D array is a row pointer, and `sizeof(&a)` is still the pointer's 8.
- **`int (*p)[3]` parses**, locally, with `p[i][j]` and `(*p)[i]` reaching the
  elements and `sizeof(p)` = 8. The declarator shares the function-pointer form:
  after `(*name)` the discriminator is what follows - `(` is a function pointer,
  `[` is an array.
- `p[i]` on such a pointer yields the ROW: its address, no load, with the row's
  strides - the state a named 2-D array has, so the same indexing code works.

Guard `cc51_mdimparam.c` grew eight checks for it (row stepping, `sizeof`, both
indexing spellings, and a `q = m` row pointer). Ceiling 21290 -> **21404**.
Corpus swept in full on the clone: 1..164 **455/455** and 165..327 **345/345**,
stdout byte-identical to gcc (164/164, 160/160); instr 142/142, hello.c 88.

`int (*p)[3]` parses in **both** places now, because the head of a declarator -
its `*`s and the `(*` that makes the name itself the pointer - is parsed once, by
`parse_declarator_head`, and asked for by both the local-declaration path and the
parameter path. They had grown separate copies of the same shape, which is how
the parameter spelling came to be missing while the local one worked. A parameter
of that type is a plain pointer whose pointee is the array, so `p[i][j]` indexes
it with no extra state. Ceiling 21404 -> **21498**; corpus 165..327 **345/345**
with stdout **160/160**; instr 142/142, hello.c 88.

Nothing is left on the list this project keeps: every divergence from gcc it has
been able to measure, and every dialect gap its own probes have found, is closed
or written down as a deliberate extension (the `word` type, char-array
assignment, implicit declarations).

**Two-dimensional array parameters, and `m[i][j]` with variable indices
(2026-11-04).** The parameter case is done, and it uncovered a worse bug than the
one it set out to fix.

- **`int a[][3]` now decays to a pointer to a ROW.** The declarator's dimensions
  were parsed and thrown away, so `a` was an `int *` and `a[i]` yielded an int -
  `a[i][j]` was "pointer type expected for indexing". The dimensions are kept
  now (0 for the one that decayed), and a parameter with inner dimensions is
  marked 2 in `lvararr`: the variable path LOADS the slot (its value is the
  address) instead of addressing it, and carries the stride vector
  `[row bytes, element bytes]`, which is the state a local `int[2][3]` has after
  its first index. `sizeof(a)` stays the pointer's 8.
- **`m[i][j]` with VARIABLE indices did not compile at all** - not for parameters,
  for ordinary local 2-D arrays. The `[` handler read the global `bstride` *after*
  parsing the index, and parsing an index variable clears it, so only constant
  indices ever worked: `int m[2][3]; m[i][j] = i*3 + j;` in a double loop was
  "pointer type expected for indexing", which is every matrix routine ever
  written. One saved copy (`sav_stride`) fixes it.
- Guard `cc51_mdimparam.c` (exit 96, gcc-identical output `21 3 60 8`): a matrix
  walk, a column extract, the 1-D form, and `sizeof` of a decayed parameter.
  Ceiling 20884 -> **21290**. Corpus swept in full on the clone: 1..164
  **455/455** and 165..327 **345/345**, stdout byte-identical to gcc (164/164 and
  160/160); instr 142/142, hello.c 88.

Two failures on the way are worth recording, because both were *mine* and both
were found only by running the other engine: a replacement lost an `end`, and two
new per-parameter cells were used without being initialised - the neighbouring
tables say `names = {}; types = {};` for a reason, and `{end+1}` on an inherited
value gave the dimension list a phantom first element. There is also an engine
bug behind that: on `cli-v13`, `c{end+1} = []` is a no-op, so appending an empty
cell element silently does nothing (filed in `matlab_in_rust/docs/`).

**The "last limitation" was already closed - and nothing tested it (2026-11-05).**
The paragraph above used to end by calling a pointer to a ROW (`&a[0] + 1`, and
`int (*p)[3]`) the one known limitation. It is not: measured against gcc, both
forms compile and step correctly, which the array-type work described earlier in
this file had already made true. What was missing was coverage - the `int (*`
matches in the corpus are all *function* pointers, and `&a[0] +` appeared in no
program at all - so a regression would have been silent while the prose claimed
breakage.

- Guard `cc52_ptrrow.c` (exit 96): `int (*p)[3]` in globals and in a frame,
  `sizeof(p)` = 8 and `sizeof(*p)` = 12, `(*p)[i]`, `p[i][j]`, `p[-1][2]` after
  `p + 1`, and a local array built through `&b[0]`.
- Guard `cc53_ptrrow2.c` (exit 96): the same row pointer with no declarator at
  all - `(*(&a[0] + 1))[1]`, `*(*(&a[0] + 1))`, `sizeof(&a[0])` = 8 and
  `sizeof(a[0])` = 12 - which exercises the address-of path instead of the parser.

Both are gcc-identical (exit 96 on gcc, the clone and the Rust engine, with the
two engines emitting the same 193 instructions each). Ceiling 21498 -> **21854**.

**The last measured gap closed, and the address-of type (2026-11-04).** The two
open items from the corner-probe round are both gone, and the second one found a
third bug on the way.

- **Addition is commutative for pointers.** `1 + p` and `1 + a` fell into the
  integer add, so the integer was never scaled: `*(1 + p)` printed 184549376
  where C says 11, and only `char *` worked (element size 1 made the error
  invisible). The additive parser had a branch for "the left is a pointer" and
  none for the right; there is one now, and it scales the *integer* by
  `elem_size(rhs_t)` and keeps the pointer type.
- **`&` on a value produced a value type.** `pdecay(t) = t + 1` survived from the
  scheme where a pointer was `base + 2*depth`; under the pointer band it returns
  a VALUE code, so `&x` on an `int` was typed `char` - which is why
  `*(1 + &a[0])` answered "bad dereference" while every use that only needed the
  address kept working. `padd()` already answers the question for both cases (a
  value type becomes a pointer to it, a pointer gains a level), so `pdecay` was
  deleted rather than fixed.
- Guard `cc50_corners.c` asserts `*(1 + a)` and `*(1 + &a[0])` now. Ceiling
  20854 -> **20884**. Corpus swept in full on the clone: 1..164 **455/455** and
  165..327 **345/345**, stdout byte-identical to gcc (164/164 and 160/160, the
  three `cc16_strarray` extensions skipped); instr 142/142, hello.c 88.

With that, every divergence from gcc this project has been able to *measure* is
closed. That is a statement about the probes, not about the language: the areas
nobody has aimed at yet are evaluation order, `switch` on 64-bit values, and
pointer-to-array arithmetic.

**The comparison operators apply the conversions too (2026-11-04).** The last
piece of C 6.3.1.8. `parse_relational` asked `sav_etype == 5` - only the exact
`unsigned int` code, and only the LEFT operand - so a relational operator was
unsigned only by luck:

  `-1 > 0u`    answered 0    C: 4294967295 > 0, so 1
  `-1 < 0u`    answered 1    C: 0
  `-5 < 3u`    answered 1    C: 0
  `0u > -1`    answered 0    correct by accident

It now takes the signedness from `arith_type(left, right)` and zero-extends both
operands when the common type is a 32-bit unsigned one, exactly as the division
does - so `setb/seta/setbe/setae` replace `setl/setg/setle/setge` on the same
decision. Equality never needed it (`==`/`!=` are sign-agnostic). The guard's
two comparison checks are back, plus `-5 < 3u`. Ceiling 20805 -> **20854**. The
corpus was swept in full on the clone afterwards: 1..164 **455/455** and
165..327 **345/345**, with every stdout command byte-identical to gcc (164/164
and 160/160, the three `cc16_strarray` extensions skipped as always). The
remaining gap from that round - array decay on the right of `+`, and the
`&`-on-a-value type behind it - is closed in the entry above.

**Six semantics bugs from one corner probe (2026-11-04).** A single C file
(`cc50_corners.c`) of well-defined language corners no existing guard covered -
shadowing, `sizeof` not evaluating, the comma operator, the conditional's common
type, enum values, switch fallthrough and negative case labels, goto across
blocks, do-while with continue, static functions, struct assignment as a value,
short-circuit evaluation, pointer arithmetic, char signedness, nested break,
multiple declarators - found six real bugs. Five were gaps that made legal C
fail to compile or report the wrong size:

- **An inner block could not shadow a local** (`duplicate local x`). The check
  asked the whole function frame instead of the current block. A `blkdecl` set,
  saved and cleared with each block, is the question C actually asks.
- **`case -2:` was a parse error.** A case label may carry a sign.
- **`sizeof(enum Tag)` was a parse error** - the type list under `sizeof(` did
  not include `enum`, which is an int.
- **`sizeof(&a)` for an array `a` reported the array size.** `&` yields a
  pointer, so the array-ness the expression carried has to be dropped.
- **A conditional with one double branch reported `double` but left an int.**
  C 6.5.15 makes the branches meet at their common type, so `1 ? 1 : 2.0` is
  `1.0`; the integer branch now widens itself before the join (branch 1's
  conversion is inserted in front of the jump it already emitted).

The sixth was arithmetic, and it is the same root cause in two places: the
**usual arithmetic conversions were not applied before dividing**. `-1 / 2u`
was 0 (a signed `idivq` of -1 by 2) where C says 4294967295 / 2 = 2147483647,
and `-1 % 2u` was 4294967295 where C says 1. Division and modulo now decide
signedness from the *common* type and zero-extend both operands to its width
first - 32 bits for `int`/`unsigned`, so the conversion happens where C does it,
not at 64 bits. Compound `/= %=` had the same bug and the same fix.

Two more gaps were found in that round - the comparison operators and the
missing array decay on the right of `+` - and **both were fixed in the entries
above**.

Guard `cc50_corners.c` (exit 96, identical output under gcc and on both
engines). Ceiling 20005 -> **20805** (the guard plus the zero-extends the
unsigned division now emits). Verified: instr 142/142 at 20805, hello.c 88, and
on the C clone `cctests,gccstdout` for 1..82 **301/301** with stdout 82/82 and
for 240..327 **235/235** with stdout 85/85.

**printf length modifiers follow the type widths (2026-11-04).** Once `long`
is 4 bytes the CRT is right by itself: `%ld` reads 32 bits, `%lld` 64, as gcc
does. But the compiler rewrote every format string first -
`%ls/%ld/%llu/%lu/%hd/%hs` to `%s/%d/%u/%u/%d/%s` - so a 64-bit argument under
`%lld` printed its low half, and the two backends were wrong differently:

  `%lld` of 1234567890123     gcc 1234567890123  gcc-assembled 1912276171  sim OK
  `%llx` of the same          gcc 11f71fb04cb    gcc-assembled 71fb04cb    sim OK
  `%lu` of (unsigned long)-7  gcc 4294967289     gcc-assembled OK          sim 2^64-7

`norm_codes` (the live normaliser - `norm_fmt` was a dead duplicate of it, with
no callers, and is deleted) passes integer length modifiers through and only
collapses `%ls`/`%hs` to `%s`, where the single string type makes the CRT's
meaning wrong. `sim_printf` learned the same rule: it ignored modifiers and
printed every integer 64-bit wide, so `%lu` of a negative came out 2^64-7. Its
width now comes from the modifier - 1 for `hh`, 2 for `h`, 4 for none or `l`,
8 for `ll` - with the value taken modulo 2^bits and sign-extended only for a
signed conversion.

Both backends print gcc's answer for the three lines above, and two guards
stopped being documented exceptions: `cc24_wide.c` prints `%lld`, and
`cc25_fmt.c` prints `%llx`/`%llu`/`%llo`/`%llX` (a plain `l` would silently
print the low half and look plausible). Both are byte-identical to gcc from
source, assembled, and through the simulator. The interpreter's `sys_prtf`
needs no change: its dialect has no `long`, so it never meets a 64-bit integer.

The corpus was swept in full afterwards - 1..80 296/296, 81..160 294/294,
161..240 255/255, 241..327 233/233 - which also closed the sweep the `long`
round owed. instr 142/142 at 20005 (format strings are data, so no instruction
moved); hello.c 88.

A probe of every modifier against every integer conversion, plus flags and
widths, found two more divergences that no guard covered:

- **Decimal literals saturated at INT64_MAX.** `int64` `*` and `+` saturate in
  MATLAB, and the accumulator used both, so `18446744073709551615ULL` became
  0x7FFF... and printed 9223372036854775807 where gcc prints the full unsigned
  value. Decimal now accumulates as two 32-bit halves (every intermediate stays
  under 2^35 and is exact) and assembles with `bitshift`/`bitor`, which wrap mod
  2^64 the way the hex path always did.
- **The `+` flag was parsed and thrown away** by the simulator's formatter, so
  `%+d` of 7 printed `7`. It now takes the slot the `-` already had, which keeps
  zero padding between the sign and the digits - and it is passed to the double
  formatter too, where `%+.2f` of 0.5 printed `0.50`.

With those, the whole matrix - `%d/%u/%x/%X/%o` at plain, `l`, `ll`, `h`, `hh`,
with negatives, widths, `-`/`0`/`+`/precision flags, `%c`, `%s` with precision -
prints gcc's bytes through the CRT and through the simulator alike.

**`long` is 4 bytes, `long long` is 8 (2026-11-04).** The value model was
LP64-flavoured: `long` was 8 bytes on a compiler that emits Win64, where gcc's
`long` is 4. So `sizeof(long)` was 8, `sizeof(1L)` was 8, struct layout with a
`long` member was wrong (`{char c; long l}` was 16 here against gcc's 8 with `l`
at 4), and `long v = 1; v << 40` stayed exact where gcc wraps to 0. Measured
against gcc, then fixed: `long`/`signed long` get their own 4-byte codes (18/21)
and `long long` keeps 17/20, so `sizeof(long)` 4, `sizeof(long long)` 8,
`sizeof(1L)` 4 and `sizeof(1LL)` 8, the structs are 8/16 with members at 4/8,
`long` arithmetic wraps at 32 bits and `1LL << 40` still works.

Two things had to move with it, and both are the point of the change:

- `num_type` implements C 6.4.4.1's candidate list instead of a flat "L means
  64 bits", and that list needs the literal's **base**: decimal considers only
  signed types, while a hex or octal literal considers the unsigned ones too.
  So `0xFFFFFFFF` is an `unsigned int` (4 bytes; it typed as 8 before this was
  read carefully) and `2147483648` is a `long long` (8). A hex pattern with the
  top bit set is >= 2^63, so `0xFFFFFFFFFFFFFFFF` is an `unsigned long long`
  (8; the raw int64 pattern looks like -1 and had typed it as a 4-byte int).
  `lex_suffix` distinguishes `L` from `LL`, and the lexer records the base as
  `token_base`, which is the only reason the two lists can differ at all.
- `mx_preamble.m` built its MEX types on `long` (`typedef long mwSize/mwIndex/
  mxChar/mxLogical/int64_t`). All five are `long long` now - `mwIndex` in
  particular must stay 8 bytes or the sparse layout indexes at the wrong
  stride, which is the bug fixed in 2f66dc6. The mx smoke and mex_run gates
  (6/6 each) can still see those types; the gcc cross-track gate cannot, because
  9 of its 20 inputs are missing from the clone's corpus.

Guards that had quietly *depended* on the 8-byte `long` were updated to say
`long long` where they meant 64 bits: `cc24_wide.c`, `cc25_fmt.c`, `cc26_word.c`
(widening into a long would truncate what it exists to check) and `cc39_wrap.c`
(which now also asserts `sizeof(1L) == 4` and `sizeof(1LL) == 8`). New guard
`cc49_long.c` (exit 96, gcc-comparable): six `sizeof`s, three struct layouts
with member offsets, 32-bit wraparound for `long` against none for `long long`,
and 2^40 needing `long long`. Ceiling 19660 -> **20005**; hello.c 88 unchanged.

`int_width` had been carrying a second copy of the width table (its `else` arm
said 4 for anything unlisted, so the new `long` codes were right by luck). It
asks `tsize` now - one table, identical mapping, and the corpus total did not
move.

**Bit-fields pack, and `sizeof` matches gcc (2026-11-04).** Consecutive
bit-fields share one storage unit - gcc's MS layout, which is what this target
(x86-64 ucrt64) uses. The key is the declared type's **size**, not its identity:
signedness does not split a unit (`{int a:3; unsigned b:3}` is 4 and
`{short a:3; unsigned short b:3}` is 2), a different size does (`{int a:3;
short b:3}` is 8, the 2-byte unit at offset 4), an unnamed `: 0` ends the current
unit, an unnamed field with a width is padding, and a plain member resumes after
the unit's whole size. The first version of this compared declared types and so
split `int` from `unsigned int`, which is why the same-size cases are in the
guard now: six of eight shapes were wrong until that was measured.

`long` bit-field shapes agree too, since the 2026-11-04 round made `long` 4
bytes: `{long a:3; unsigned long b:3}` and `{int a:3; long b:3}` are both 4,
as gcc has them. The shapes that were 2-4x too big are now
exact, measured against gcc: `{unsigned a:3; b:5}` 4, `{int a:4; b:4; c:4;
d:4}` 4, `{unsigned char a:3; b:5}` 1, `{char c; unsigned short a:4; b:4}` 4,
`{unsigned short a:9; b:9}` 4, `{u:3; u:5; int n}` 8 with `n` at 4, an array of
the first striding 4, and the mixed-type `{u:3; uc:3}` 8 with the next member
at 5.

Packing is what makes the *store* change too: with several fields in one unit a
plain write would erase its neighbours, so every store is now a masked
read-modify-write - read the unit at the declared type's width, clear the
field's bits, or the masked value in, write the unit back. One helper
(`em_store_bitfield`) owns that sequence for all three store sites (plain
assignment, compound assignment, `++`/`--`), and `store_member` applies the same
rule in the initializer image, so a data-section or frame initializer merges
into the unit instead of overwriting it. The field's place in its unit is the
`membermap`'s sixth field, and `member_bitfield` is the only place that reads
it: the load site records the answer in `lbf`, `lvalue_addr` hands it back as
`bf` while dropping the extraction, and the three store sites mask from that -
nothing re-derives it, and no reader has to agree by luck.

Guard `cc48_bitfield_layout.c` (exit 96, identical output on gcc and both
engines): fifteen `sizeof`s, two member offsets, an array stride, the
neighbour-preserving store, compound and `++`/`--`, 4-bit wraparound
(`7++` is -8, `-8--` is 7), `int:4` sign preservation, a unit shared by an `int`
and an `unsigned int` field (each keeps its own reading), struct copies and
initializer images. Ceiling 18284 -> **19474** (the guard is 1118; the masked
stores added 72 to `cc31_bitfield.c`), then **19660** (+186 for the same-size
cases), hello.c 88 unchanged.

**Function prototypes (2026-11-04).** `int f(int);` — a declaration with no
body — was a parse error (`expected token 123, got 59`: every file-scope
`type name(params)` had to be a definition), so forward declarations, the
declarations mutual recursion wants, and the header-free way to declare a
variadic function (`int printf(const char *, ...);`) were all rejected. A
prototype is now parsed and discarded: a call records its own arity in
`called` and `parse_program` checks every call against the definitions at the
end, so a declaration needs no registration, and a declared-but-never-defined
callee is still `call to undefined function`. Two gaps came with it: an
**unnamed parameter** (`const char *`) was `expected a parameter name` — legal
in a declaration; it now keeps its stack slot and binds nothing, and a
*definition* still rejects it (`a parameter of a definition needs a name`,
which is the error gcc gives too) — and `...`
had no token at all (new token 210, lexed only for three dots, so `.` stays
member access). Guard `cc47_proto.c` (exit 96: mutual recursion through
prototypes, unnamed and variadic forms); ceiling 18120 → **18284** (the guard
is 164 of it).

**Bit-fields (2026-10-02).** `struct S { unsigned int a : 3; int b : 5; };`
parses and works: a read returns only the field's `width` bits, sign- or
zero-extended per the declared type, so the value is confined to the field.
The width is recorded in the membermap and applied on load
(`shlq $(64-width); sarq|shrq $(64-width)`), leaving the store path
untouched, and `lvalue_addr` drops the extraction shifts along with the
load. A field owns a whole 8-byte-aligned slot (no packing) — consistent
with the already-coarse struct layout, though it does not reproduce gcc's
`sizeof`; the values do match gcc. Guard `cc31_bitfield.c` (exit 96,
gcc-comparable: `7 -16 1`); ceiling 14448 → **14584**.

**typedef of struct/union, pointer and array types (2026-09-29).** `typedef`
stored only a scalar base code and rejected struct definitions outright, so
`typedef struct { … } P;`, `typedef int *ip;` and `typedef int ia[3];` all
failed. The alias is now `{base + 2*depth, dims}` — a struct/union definition
is registered, trailing `*`s join the code, trailing `[n]` become the alias's
dimensions — and callers still add 2*(their own `*`), so `ip *pp;` and
`typedef ia ib;` compose. `parse_basetype` returns those dims as a third
output, honored by the local/global declaration paths and `sizeof(<typedef>)`
(which lacked the typedef-name case), with a new `val_size()` for an array
typedef's element size. Guard `cc30_typedef.c` (exit 96, gcc-comparable);
ceiling 14303 → **14448**.

**Unions and anonymous struct/union (2026-09-29).** `union` is a C type with
every member at offset 0, sized to its largest member (C 6.7.2.1). It reuses
the struct machinery (`parse_struct_members` takes an `isunion` flag; the
membermap/`ssize_of`/`member_lookup` paths are shared; a union initializer
sets only its first member), and tagged unions work at file scope, inline and
nested. Two related gaps went with it: **anonymous `struct { … } s;` /
`union { … } u;`** are accepted (a synthetic tag is registered) — including as
members and inside `sizeof(struct { … })`, which used to size the anonymous
type as int — and **member types go through `parse_basetype`**, so
`short`/`word`/`long`/`unsigned`/typedef'd members work (previously
int/char/double/struct only). Guard `cc29_union.c` (exit 96, gcc-comparable);
ceiling 14150 → **14303**.

Three things on that list were stale by 2026-11-05, and the fourth was not what
it said (measured against gcc):

- a struct/union *definition inside a typedef* (`typedef struct { … } P;`) works -
  `td.c`, six members through four typedef'd definitions, exit 21 as gcc says;
- array members (`struct S { char c[4]; }`) work - guard `cc35_memberarr.c`;
- local aggregate initializers (`struct S s = {1,2};`) work - exit 3 as gcc says;
- but a **tag used inside its own body** did not parse at all, with or without a
  typedef: `struct Node { struct Node *next; }` failed with "unknown tag Node",
  because the tag was registered only after the closing brace. That is the
  linked-list idiom, and it was not merely a typedef gap.

Fixed by taking C 6.7.2.3p8 literally: the tag is in scope from the moment it is
seen. `parse_basetype` registers the id before the members are parsed and
`register_struct` completes it (failing only on a real duplicate), and a tag that
is *mentioned* before its body - `struct A { struct B *b; };` above B's definition
- is registered as an incomplete type, which is what C does; only a use that needs
the layout fails, through `sdef_of`, with "incomplete struct type". Pointer to an
incomplete type is legal C and now compiles. Guard `cc54_tagscope.c` (exit 96):
self-reference with and without a typedef, a forward tag, a union, nested
anonymous structs, and a local list built through a self-pointer. Ceiling
21854 -> **22086**.

**Two declarators in one typedef (2026-11-05).** The gap named above is closed:
`typedef struct { … } T, *PT;` reported "expected token 59, got 44" because the
typedef branch read one declarator and then demanded the ';'. A typedef declares a
LIST, and `*` and `[` belong to each declarator rather than to the typedef -
`typedef int A, *PA, B[3];` names three different types - so the branch loops over
them now, resetting the pointer depth and inheriting the array dims per declarator.
Guard `cc55_typedefs.c` (exit 96): a definition plus a pointer to it, a
self-referential struct plus its pointer, a scalar/pointer/array trio, a union twice,
and file-scope declarators from those typedefs. Ceiling 22086 -> **22332**.

**A typedef'd function pointer, and the parser copy that lost a form (2026-11-05).**
Reviewing the typedef loop turned up a second defect behind the first: the branch
parsed its own declarator (`*`s, name, `[`s) while `parse_declarator_head` exists so
that "all the parsers" share that shape — its comment said *both*, and the typedef
branch was a third that never asked. Its copy had lost the parenthesised form, so
`typedef int (*FP)(int);` failed with "expected a typedef name" while the identical
form on a variable had always worked. All three now ask the shared head, and the
alias's bytecode is a named pair (`.code`, `.dims`) instead of a two-cell read by
position. Guard `cc56_fptr_alias.c` (exit 96): locals, a global, a parameter, a call
through the alias, and two pointers declared by one typedef. Ceiling 22332 ->
**22493**.

**Function-pointer members: the parser was one half, a copied predicate was the other
(2026-11-05, measured).** The member parser was the last copy of the declarator shape
and it had no parenthesised form either - `struct S { int (*f)(int); }` failed with
"expected a member name" (gcc: 42). All four parsers (variable, parameter, typedef,
member) now ask `parse_declarator_head`.

The parser was the easy half, and the obstacle behind it was *not* where it looked. Reading
such a member emitted the struct's ADDRESS where the member's value was due -
`p = s.f;` became `leaq -8(%rbp), %rax; movq %rax, p` - a silent miscompile. That was
first blamed on `lvalue_addr` and written up as an instruction-matching problem; measuring
showed the member access never reached `lvalue_addr` at all. Six places spelled "is this a
struct value?" by hand as `t >= 1000 && ~is_ptr_code(t)`, and a function-pointer type is
`2000 + return type`: over 1000, not a pointer code. Every copy took the struct branch.
`is_struct_code()` is that predicate, written once and excluding both bands; all six ask it
now. Assignment failed for the same reason (a struct-typed target is not a store target),
not because of the load list.

Guard `cc57_fptrmember.c` (exit 96) covers the member read, store, size and call, plus a
nested member, an array of members, a global struct and `->`. Ceiling 22493 -> **22703**.
The lesson is the session's recurring one: the bug was in a *copy* of a predicate, and the
copy that was wrong was the one nobody had exercised with the type that breaks it.

**Returns anywhere + `extern` (2026-09-29).** `parse_body` stopped at the
*first* top-level `return` (a tutorial simplification), so a label after a
return, a second top-level return, or dead code after one was a parse error
(`int main() { return 1; skip: return 9; }` → "expected 125, got 150") —
all valid C. It now parses statements to the function's `}`; the epilogue
label still collects every return. `extern` is accepted as a no-op
qualifier. Guard `cc28_flow.c` (exit 96, gcc-comparable); ceiling 14072 →
**14150**.

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
| cc19 | hexadecimal integer literals | `0230f27` |
| cc20 | octal literals (silent-miscompile fix) + literal-forms corpus | `1a5b710` |
| cc21 | local short/word/long declarations, casts, sizeof | `dd7fb97` |
| cc22 | escape sequences (both tracks) | `0dc3320` |
| cc23 | integer constant suffixes (both tracks) | `f06ee02` |
| cc24-cc58 | doubles, bit-fields, aggregates and elision, unions, `long` widths, corner cases, pointer-to-row in all three declarator positions, tag scope, typedef declarator lists, function-pointer aliases and members | see the dated notes above |
| double | SSE value model in `cc_int` + `x86sim` + gcc-parity corpus | `e2b4c8d` |
| mex | in-memory `mxArray` ABI, `mex_run` driver, gcc reference track | `e502237`…`6276c06` |
| parity | cross-track exit-code parity (187) + output parity (53, 47/47 matchable `pp_*`) | `04da1b7` `57e2fae` |
| verify | reference cross-check + ENT dump fix | `f697b72` |

## Verification

- **`tests/probe_matlab_portability.m` — the one claim this project has never
  tested (2026-11-04).** Every number here is measured against gcc and two
  runtimes, none against MathWorks MATLAB, which has no runnable install on the
  development machine. The probe checks the language rules the compiler leans on
  and then compiles three corpus programs and compares their x86sim exit codes
  with the clones' answers. One command on a real MATLAB:

      >> addpath('tests'); probe_matlab_portability

  It checks that a function reading an undeclared global is an ERROR (the premise
  `check_globals` is built on), that `c{end+1} = []` grows the cell, that
  `bitshift` on int64 wraps while `int64` `+` saturates (the literal paths depend
  on both), and that text-mode `fopen` strips CRs (`run_out` depends on it).
  Run against the two runtimes it settles them: the C clone passes **8/8**; on
  `cli-v13` the only failure is the filed `c{end+1} = []` bug, which this
  reproduces from a second direction. `sprintf('%d', int64)` past 53 bits is
  reported as INFO: both clones round through a double (2^53+1 prints as 2^53),
  real MATLAB is exact, and the compiler does not depend on it because wide
  literals are emitted in hex.

  **First real-MATLAB run (R2023b 23.2.0, PCWIN64, 2026-11-04).** Four of the
  language rules hold there exactly as assumed - a function reading an undeclared
  global IS an error (so `check_globals` protects against something real), empty
  cell appends grow, `bitshift` wraps, `int64` addition saturates - and
  `sprintf('%d', int64)` is exact. Two things did not:

  - text-mode `fopen` does **not** translate CRLF there (a 6-byte `a
b
`
    reads back as 6 chars, where both clones give 4). `run_out` had stopped
    stripping CRs on the clones' behaviour; it strips them itself again, which is
    a no-op on the clones and correct on real MATLAB.
  - **the compiler did not run there**: every compile stopped with "Operands to
    the logical AND (&&) and OR (||) operators must be convertible to logical
    scalar values". The stack named `parse_unary`'s `if at == 6 || dt == 6`: `dt`
    is `[]` whenever a call's argument type is unknown - which is every variadic
    argument, i.e. every `printf` - and `[] == 6` is EMPTY, which real MATLAB
    rejects inside `||` while the clones read it as false. Guarded like the two
    tests above it. A sweep of every `src/` file for that whole class (a variable
    that can be `[]`, compared without `isempty` inside a logical chain) now finds
    none, and no `(end+1) = []` null-assignment growth remains either.
- **Run the compile-heavy sections on the C clone; keep `cli-v13` for engine
  compatibility (measured 2026-11-04).** The same `src/` code is far cheaper to
  run on the clone: `CC_SECTIONS=instr` (all 327 corpus programs compiled and
  counted) takes **183 s** there against **798 s** on the Rust engine, with
  identical numbers - corpus 20005, hello.c 88, 142/142. A 12-program
  `gccstdout` slice is 96 s against ~200 s. The reason is in the other repo's
  note: on `cli-v13` a compile costs 270x the clone's and grows superlinearly
  with source size (a 10 KB file parses in 18-26 s against 0.096 s), while every
  primitive in isolation - `fileread`, indexing into local and global `char`
  arrays, the tokenizer's own skip loop with its eight globals - measures fast.
  So the engine's slowness is not attributable to this code, and verification
  should not pay for it: use the clone for sweeps, and run one section on
  `cli-v13` when an engine-compat claim is what is being checked.
- **Every corpus program's stdout is compared with gcc's own build of the same
  source (2026-11-04, `CC_SECTIONS=gccstdout`).** 333 of the 336 programs are
  byte-identical; the three skipped are `cc16_strarray{,2,3}.c`, which assign to
  a `char` array - the port's extension, invalid C in every dialect. Two things
  make it work: the reference build asks for `-std=gnu89`, because the corpus
  declares nothing (`printf`, `malloc` and its own functions come from the
  port's `libfns` table), which is legal C89 and an error in C23 - without that
  flag ten programs look uncompilable when they are merely dated; and stdin is
  redirected from `NUL`, because the syscall tests read it and would block
  otherwise. Skips are printed by name, so an exclusion cannot go quiet. This is
  the oracle that would have caught the truncated `%lld` and the saturating
  literal before they were found by hand: exit codes cannot see a wrong print.
- **Every section verified on `cli-v13` after the bit-field round
  (2026-11-04)**, sliced with `CC_SECTIONS`/`CC_CORPUS` because a whole-suite
  run is 25+ minutes here: tables **245/245**, ostests **196/196**, instr
  **142/142** (corpus 19660, hello.c 88 - this section compiles all 326 corpus
  programs, so it counters every one of them), and the corpus itself in five
  slices - 1..80 **296/296**, 81..100 **179/179**, 101..180 **283/283**,
  181..240 **227/227**, 241..325 **231/231** - plus the guard range 320..327
  **147/147**. Guards `cc31_bitfield` and `cc48_bitfield_layout` also exit 96
  on the C clone, and `cc48` under gcc itself.
- **Test suite**: `tests/run_tests.m` — **802/802** on the C clone
  (v1.3.76 tag and the Sep 27 build). Groups: runtime-primitive
  gate (probe), 30-case VM selftest, 9-case lexer selftest, program
  corpus (p3–p6, pp), syscall/acceptance, `-s`/`-d` smoke, the gcc-gated
  assembly-track group + cross-track parity + output parity, the gcc-free
  x86sim corpus group (`x86sim.m` runs every compiler program without
  gcc), the instruction-count regression, the peephole-pass unit
  fixtures, and the static globals audit. Since the 2026-08-18 fix round
  the gcc-free groups run even when gcc is absent, and the harness
  invokes the compiled exe as `.\tmp_cc.exe` (cmd's current-directory
  exe lookup under `NoDefaultCurrentDirectoryInExePath`). Every check is
  appended to `run_tests.log` as it runs, so a killed run still leaves a
  record.
- **Hosts** (2026-09-29; **superseded - see the 2026-11-05 notes at the top of this
  file**): the suite runs on the custom C clone and on the matlab_in_rust engine. The
  numbers below are that day's, kept because the root cause they record is worth
  knowing; the engine has since had that quadratic store fixed and now runs the whole
  suite, and a runnable real MATLAB is available and has verified 832/832. The C clone (v1.3.76 tag and the Sep 27 build) =
  **802/802** plus the four gates. The Rust engine (2026-09-29 build)
  reaches 588 checks with 0 failures and then hangs on
  `xc('tests/programs/stress2.c')` — the *compiler* track runs that same
  program fine, so it is the interpreter. Root cause (filed as issue 1 of
  the engine bug report): an indexed write into a large **global** array
  copies the whole array, and the VM's `mem` is one such global, so every
  interpreter store is O(|mem|) and store-heavy programs go quadratic
  (9.2 ms per element write at 2M elements vs 0.0024 ms on the C clone; a
  local array is fine). The corpus instruction total is
  identical on both engines (14448) after the peephole rule-3 fix (§E of
  `docs/2026-09-07-x86sim-peephole-divergences.md`), and the emitted
  assembly is byte-identical across the two engines for all 308 corpus
  programs — a verified second oracle for the compiler track. Earlier runs — v1.3.72
  = 775/774/1, v1.3.53 and v1.3.68 = 584 / 183 failed, v1.3.47 = 577 / 191.
  No runnable MathWorks MATLAB was installed on the development machine that day (the
  R2023b install was a stub with no `matlab.exe`), so the suite's "green oracle" was
  unverified on it then. **That is no longer true**: R2024b is installed and has now
  verified **832/832** twice, and it is the runtime that found the three defects the
  clones could not (2026-11-05 notes at the top of this file).
- **Reference cross-check**: the reference `xc.c` built with gcc 15.2.0
  (`C:\msys64\ucrt64\bin\gcc.exe`). Every corpus program's exit code is
  identical to the reference; `-s` instruction dumps are byte-identical
  modulo absolute-address jump targets (the port uses slot indices — an
  inherent consequence of the two-space memory model); `hello.c` stdout is
  byte-exact (the fibonacci table + `exit(0)` with no trailing newline) and
  is asserted in the suite with its full expected output.
- **Regression**: the probe gate re-verifies the primitives the port depends
  on before every run, so a runtime behavior regression fails loudly.

## Open items (2026-09-29)

- **`CC_CORPUS` used to slice only two of the three corpus loops (fixed
  2026-11-04).** The gcc-free x86sim track compiles and simulates every corpus
  program and logs nothing unless a check fails, so with the slice ignored there
  it ground through all 326 of them on every run - and a 20-program slice looked
  like a hang with no progress at all, after the pp parity group, for anything
  up to fifteen minutes. That is what three "the host wedges" runs actually
  were; `xc` and `cc_int` were never at fault, and the engine is not either.
  Fixed by giving that loop the same `corpus_first:corpus_last(...)` bounds the
  other two use: `CC_SECTIONS=cctests CC_CORPUS=81:20` now finishes in 6
  minutes with 179/179 instead of timing out. If a sliced run seems to stall,
  check whether the section loop it is in honours `corpus_last` before blaming
  the host.
- **Real-MATLAB validation: the compiler runs there; the SUITE has not.** The
  probe passes 7/7 on R2024b (see the entry above), so the target runtime is no
  longer unverified for "does it work". What is still unmeasured on it: the
  ~800-check suite. `bash tests/run_all.sh` cannot run on that machine (no bash,
  no gcc), but the suite itself can and skips its gcc-gated groups when gcc is
  absent:

      >> addpath('tests'); run_tests

  The instruction-count ceiling remains a clone-lineage baseline, not a
  real-MATLAB number, until that run happens.
- **matlab_in_rust engine now on `cli-v13` (2026-11-04).** Tagged at the
  repo's `083452f`; `dist/matlab-cli/matlab.exe` is 20,533,155 bytes and
  md5-identical to `target/release/matlab.exe`, so the cut is the build it
  claims to be. It closes the last engine gap tracked here: a **brace write
  now nests a 1x1 cell** (`c{1} = {'x'}` leaves a cell; a paren write into a
  cell still unwraps - `c(2) = {7}` stores 7, invisible through `c{2}`).
  `tests/probe_globinit2.m` goes from claim E FAIL on v12 to **C, E, D, A, B,
  B2, B3 all PASS**: `numel(out)` 51 -> **45** (the C clone's count), one 1x7
  cell instead of seven characters, the assembly file **727 bytes / 45
  lines, byte-identical to the C clone**, gcc accepts it and the program
  exits 42 - the whole `pp_globinit2` residual is gone. Verified on v13:
  double regression 13/13, tables 245/245, instr 142/142, ostests 196/196,
  corpus slice programs 1..80 = 296/296.
- **Run the suite through `tests/env.sh`, not by hand.** `run_tests.m` reads
  `TMPDIR`/`TMPWIN`/`CC_REPO` from it; invoking the runtime as
  `matlab -e "addpath('tests'); run_tests"` works for the table sections but
  makes the *corpus* report mass failures (`CC_CORPUS=1:80` gave 155 of 305
  failing, then the same slice was 296/296 the moment `env.sh` was sourced).
  The corpus compiles and runs programs, so the missing scratch paths land
  everywhere. Use `bash tests/run_all.sh`, or `. tests/env.sh` and then
  `"$MATLAB" tests/run_tests.m`, for anything involving the corpus.
- **matlab_in_rust engine — the three filed gaps are FIXED (2026-10-02
  `dist/matlab-cli` build).** Interpreter: 200 calls 37.6 s → **0.34 s** and
  `xc('tests/programs/stress2.c')` **finishes in 5.0 s** (was a >9-min
  hang). `find`/`nonzeros`/`sum`/`double`/transpose on a sparse, and
  `s.(name).field = value`, both work now. The gates pass individually
  (double 13/13, mx smoke 6/6, mex_run smoke 6/6). `run_all` — the documented
  one-command gate — needs about **30 minutes** on the C clone (instr 200 s,
  cctests 500 s, gccstdout 550 s, tables 200 s, ostests 250 s, gates 60 s) and
  about four times that on `cli-v13`, so it is run as sections rather than as one
  command; a 28-minute window stops inside the stdout sweep, which looks like a
  hang and is not. The gcc cross-track 15/20 was
  **shared with the C clone** and **is now fixed** (2026-10-02): the mex
  input count was stored with `sim_storeN(nrsec, nk, 8)` though
  `__mex_nrhs` is a 4-byte `int`, so the extra bytes overwrote the next
  global — in `mxprint.c` that is the first format string, which then read
  empty. Storing 4 bytes fixed `mxcell_get`, `mxstruct_get` and `mxprint`. The
  other two (`mxsparse_build`/`mxsparse_get`) were a second regression from
  the same int-width change: `mx_preamble` had `typedef int mwSize/mwIndex`,
  which silently became 4 bytes, while the sim's sparse layout (and the real
  MEX API) index `ir`/`jc` with 8-byte words. Both are `long` now. The gcc
  cross-track gate is **20/20** and `run_all` is 5/5. See
  `MATLAB_in_C/docs/BUG_REPORT_2026-10-02_mex_cross_track_regression.md`.

## Post-parity features (beyond the reference)

- `/* */` block comments (multi-line, line-counted; unterminated → error)
- Function prototypes: `int f(int);` with no body, unnamed parameters and a
  variadic tail (`int printf(const char *, ...);`); a call to a function that
  is declared but never defined is still an error
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
- printf length modifiers mean the widths they name: `%d`/`%u`/`%x`/`%o` read
  32 bits, `%ld`/`%lu`/`%lx` the same (long is 4 bytes here), `%lld`/`%llu`/
  `%llx` 64, `%hd`/`%hhd` 2 and 1; `%ls`/`%hs` collapse to `%s` because there is
  one string type; `%*` dynamic width/precision; `%n` writes the running
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
structs; the cc18 round closed its last three documented gaps
(pointer-returning function pointers, compound literals, `unsigned` types),
and the cc19 round added hexadecimal integer literals, the cc20 round
octal — closing the compiler-track dialect gaps in the number lexer. Calls through pointers always use the
interpreter-style stack convention.

- The `-s` mnemonic column is padded manually to reproduce the reference's
  `%8.4s` over its 4-char mnemonic field (`'LEA '` -> `'    LEA '`), which
  matches byte-for-byte on every runtime

## Runtime notes

The port follows **real MATLAB semantics**: int64 arithmetic saturates at
INT64_MAX/MIN, integer division keeps its class with half-away-from-zero
rounding, bitwise ops preserve the sign bit. VM DIV/MOD keep C truncation
via `cdivmod` (exact double math, values < 2^53 — `word_store` asserts the
bound). The port targets the current runtime; historical behavior gaps and
their resolutions are tracked in the (internal, gitignored) runtime bug
report. The suite is verified green on both the released `v1.3.76` tag and
the current build (802/802 plus the four gates), which is why a few
workarounds whose original reason is fixed upstream are kept — they cost a
few lines and keep older runtimes working.
64-bit integers are transported exactly end-to-end: a decimal literal is
accumulated in `int64` by the lexer, emitted from the exact `int64`,
parsed back byte-exactly by `x86sim` (`sim_num64`/`sim_storeN`), and
printed by `sim_decstr`/`fmt_int` in `int64` (INT64_MIN included). The
peephole never folds a full-width immediate into a memory operand, since
x86-64's `movq`-to-memory takes only a sign-extended imm32. The current
clone also enforces real MATLAB's rules the older clones ignored —
`evalc` echoes an unsuppressed assignment, integer arrays cannot be
combined with a non-scalar double array, and one function convention per
file — so the harness and probe now respect them.

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
%MATLAB% tests/run_tests.m                                       # the whole suite
%MATLAB% -batch "addpath('src'); xc('tests/programs/hello.c')"   # acceptance program
%MATLAB% -batch "addpath('src'); xc('-s', 'tests/programs/hello.c')"  # compile dump
%MATLAB% -batch "addpath('src'); xc('-d', 'tests/programs/hello.c')"  # trace
```

`%MATLAB%` is the runtime described under Requirements in `README.md`; there is no launcher
script in this repository. `tests/run_all.sh` runs the suite and the MEX gates with one exit
status, and `CC_RUNTIMES="<a>;<b>"` runs it on each and diffs the failure sets.

See `README.md` for the three artefacts and the layout.

## What is deliberately not done

The assembler's plan keeps the list, with the reason for each item in
[PLAN_assembler.md](PLAN_assembler.md): section layout and an executable image (a new
project), multi-file relocations, and a linker - which needs objects first and would cost the
text seam that makes this toolchain verifiable. A flat-binary loader for `x86sim` was
considered and rejected with its reasoning, rather than left as an open invitation.
