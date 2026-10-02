# Project Status — last updated 2026-09-19

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
interpreter's narrow-string convention — the compiler now normalises the
same length modifiers as xc.m. Plus non-constant global initializers
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
long accepted `short` (2-byte), `word` (4-byte) and `long` (8-byte), but
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
previously +8). Intermediate int arithmetic is still 64-bit and struct
alignment stays 8-byte coarse — documented deviations. Guard `cc27_int.c`
(exit 96, gcc-comparable); ceiling 11673 → **14072**, hello.c 72 → 84.

Interpreter divergence: `xc`'s VM word is 8 bytes (`sizeof(int)` = 8), its
own model (a port artifact of xc.c's int-word VM); `cc13_si1.c`/`cc13_si5.c`
left the cross-track parity list for that reason.

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

Still unsupported: a struct/union *definition inside a typedef*
(`typedef struct { … } P;`), array members (`struct S { char c[4]; }`), and
local aggregate initializers (`struct S s = {1,2};`) — all pre-existing.

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
| double | SSE value model in `cc_int` + `x86sim` + gcc-parity corpus | `e2b4c8d` |
| mex | in-memory `mxArray` ABI, `mex_run` driver, gcc reference track | `e502237`…`6276c06` |
| parity | cross-track exit-code parity (187) + output parity (53, 47/47 matchable `pp_*`) | `04da1b7` `57e2fae` |
| verify | reference cross-check + ENT dump fix | `f697b72` |

## Verification

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
- **Hosts** (2026-09-29): the suite runs on the custom C clone and on the
  matlab_in_rust engine. The C clone (v1.3.76 tag and the Sep 27 build) =
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
  No runnable MathWorks MATLAB is installed on the development machine
  (the R2023b install is a stub with no `matlab.exe`), so the suite's
  "green oracle" is still unverified on it.
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

- **Real-MATLAB validation.** No runnable MathWorks MATLAB is installed
  here (the R2023b install is a stub with no `matlab.exe`), so the
  suite's "green oracle" is unverified on it. The instruction-count
  ceiling is a clone-lineage baseline, not a real-MATLAB number.
- **matlab_in_rust engine — the three filed gaps are FIXED (2026-10-02
  `dist/matlab-cli` build).** Interpreter: 200 calls 37.6 s → **0.34 s** and
  `xc('tests/programs/stress2.c')` **finishes in 5.0 s** (was a >9-min
  hang). `find`/`nonzeros`/`sum`/`double`/transpose on a sparse, and
  `s.(name).field = value`, both work now. The gates pass individually
  (double 13/13, mx smoke 6/6, mex_run smoke 6/6); `run_all` still cannot
  complete here because the loaded host kills the process mid-run with 0
  failing checks (the C clone behaves the same). The gcc cross-track 15/20 was
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
D:\...\matlab.bat tests/run_tests.m          # full suite (802 checks)
D:\...\matlab.bat -batch "addpath('src'); xc('tests/programs/hello.c')"   # acceptance program
D:\...\matlab.bat -batch "addpath('src'); xc('-s', 'tests/programs/hello.c')"  # compile dump
D:\...\matlab.bat -batch "addpath('src'); xc('-d', 'tests/programs/hello.c')"  # trace
```

See `README.md` for both tracks and the layout.
