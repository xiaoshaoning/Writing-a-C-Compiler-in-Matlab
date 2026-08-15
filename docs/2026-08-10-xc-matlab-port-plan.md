# xc.m — C Interpreter in MATLAB: Implementation Plan

> **Status:** All phases 0-7 complete — full feature parity reached
> (hello.c byte-exact vs the reference, suite green 208/208), plus post-parity
> additions (block comments, %s, arrays, initializers, void, multi-read —
> suite 208/208).
> **For agentic workers:** phases use checkbox (`- [ ]`) syntax for tracking. This
> project is a git repository — commit after each verified phase; verify via the
> stated test commands instead.

**Semantics contract:** the port follows real MATLAB behavior (R2024b-class
semantics): int64 arithmetic saturates at INT64_MAX/MIN and integer division
keeps the integer class with half-away-from-zero rounding. The interpreter's
*language* semantics stay C: VM DIV/MOD truncate toward zero via `cdivmod`
(exact double math), and pointer/word arithmetic is exact because every value
is < 2^53 (`word_store` asserts). The two contracts never collide — the test
corpus never overflows.

**Goal:** Single-file MATLAB port of `D:\Projects\github\write-a-C-interpreter\xc.c`
(a self-hosting C interpreter derived from c4) with full feature parity,
implemented in core MATLAB (no toolboxes).

**Architecture:** Port the whole xc.c pipeline — lexer → recursive-descent parser
with on-the-fly codegen → 38-op stack VM (`eval()`) — into one file `xc.m` at the
repo root, local functions mirroring xc.c 1:1. C's raw pointers become
segment-local integer indices; the VM byte/word memory model is reimplemented
with a single `uint8` array plus `typecast` loads and manual byte-decomposed
stores. No self-interpretation (user decision).

**Tech Stack:** MATLAB language only (no toolboxes), R2023b-compatible syntax.

---

## Acceptance Criteria

1. `xc('tests/programs/hello.c')` prints the fibonacci table 0..10 identical to
   the reference C build (`./xc hello.c` in the reference repo).
2. `-s` (source + instruction dump) and `-d` (execution trace) flags work.
3. `cc_int.m` (assembly track) is untouched and still works from the new layout.
4. All tests in `tests/run_tests.m` pass in a single test-runner invocation.

## Files

| Path | Responsibility |
|---|---|
| `xc.m` (create) | The interpreter: `main` + local functions `next`, `match`, `expression`, `statement`, `enum_declaration`, `function_parameter`, `function_body`, `function_declaration`, `global_declaration`, `program`, `vm_eval` (renamed from xc.c's `eval`) + helpers `emit`, `word_load`, `word_store`, `align8`, `fail`, `opname`, `cdivmod`, `vm_selftest`, `run_case` |
| `tests/run_tests.m` (create) | Test harness: table of {name, source, expected stdout, expected exit}; runs `xc` in-process, captures output via `evalc` (verified working), diffs |
| `tests/programs/*.c` | Test corpus: `return_2.c`, `hello.c` (copied, GPL2 attribution), plus per-phase programs |
| `tests/probe_primitives.m` (create, Phase 0) | Runtime feature gate — re-verifies the primitives the port depends on before any other test |
| `cc_int.m` | Assembly track (Norasandler part 1). Two minimal fixes during reorg: `regexp` extraction rewritten to avoid quantifier patterns, and COFF-compatible `.def/.scl/.type/.endef` directives (ELF `.type main, @function` is rejected by MSYS2 binutils). Output semantics unchanged — see README. |

## Runtime Constraints

Core MATLAB only (no toolboxes); the primitives the port depends on are
re-verified by `tests/probe_primitives.m` before every test run.

Safe primitives (use these):
- `zeros(1, N, 'uint8')` / `zeros(1, N, 'int64')` typed arrays + element/slice
  assignment, incl. converted arrays (`uint8([...])`), `(end+1)` appends
- `typecast(mem(a+1:a+8), 'int64')` — word LOAD (slices keep their uint8 type)
- `mod(int64, int64)` keeps the int64 class, exact for |x| < 2^53; int64
  scalar arithmetic — exact for |x| < 2^53
- `uint8` `bitand`/`bitor` for small values, `find`, logical indexing, `[a b]` concat
- `global` keyword; `evalc` (captures disp AND fprintf); `error`/`try-catch`;
  `sprintf`; `fopen`/`fgetl`; `fread(fid, inf, 'uint8')` (plain `fread` reads
  double units); `addpath`; local functions with multiple outputs; local calls
  nested in call argument lists

Watch out for:
- Integer `/` on typed operands — keeps the integer class with R2024b
  half-away-from-zero rounding (7/2 = 4, not C's 3); the port never divides
  int64 directly — `cdivmod` (VM DIV/MOD) and `word_store`'s byte
  decomposition use exact double math, preserving C truncation semantics
- `delete(file)` removes files (test cleanup works)
- Shared state must live in `global` variables (see State Sharing)

## State Sharing (replaces xc.c globals)

Shared state lives in `global` variables:

```matlab
% every local function touching shared state starts with its own global line:
global token token_val src si line text ti pc bp sp ax cycle ...
       symbols symbol_names current_id idmain mem data_top hp stack_base poolsize ...
% xc.c globals → MATLAB:
%   token, token_val, src(char vector), si(source index), line
%   text(int64), ti(text emit index), pc, bp, sp, ax, cycle
%   symbols(int64 matrix), symbol_names(cell of char), current_id(row index)
%   idmain(row index), mem(uint8), data_top, hp(heap bump), stack_base
```

`fail(line, msg)` = `error(sprintf('%d: %s', line, msg))` mirroring xc.c messages.

## Memory Model (0-based byte addresses)

```
mem  = zeros(1, 3*P, 'uint8'),  P = 256*1024
  [0,      2*P)   data region: globals at 8-byte stride from 0; strings byte-wise;
                  heap bump pointer hp starts at data_top after compile
  [2*P,    3*P)   stack region: grows down from 3*P (sp initialized to 3*P)
text = zeros(1, 32768, 'int64')   0-based word index; ti = emit index; pc = index
symbols = zeros(3276, 10, 'int64')  symbol table; rows = symbols
symbol_names = cell(3276, 1)         identifier strings (replaces xc.c Name source-pointer)
```

Symbol column mapping (xc.c field → column, 1-based):

| xc.c field | Token | Hash | Name | Type | Class | Value | BType | BClass | BValue |
|---|---|---|---|---|---|---|---|---|---|
| column | 1 | 2 | 3 (unused) | 4 | 5 | 6 | 7 | 8 | 9 |

Classes: `Num=128, Fun, Sys, Glo, Loc` (token enum values, C-identical).
Types: `TYPE_CHAR=0, TYPE_INT=1, TYPE_PTR=2+`. `current_id` = row index;
`id[Class]` → `symbols(k,5)`, etc. Lookup: hash `h = h*147 + c` over the
identifier, linear scan by hash + `strcmp` against `symbol_names`.

## Byte↔Word Scaling Table (every pointer-arithmetic op ×8)

pc is a **1-based text index**; slot 0 is unused (mirrors xc.c's `text[0]`),
so the first emitted instruction sits at text(2) and the parser's function
Values are 1-based indices. Jump/call operands stay **0-based slot targets**
(what the parser backpatches): a taken jump sets `pc = target + 1`.

| xc.c | Byte model |
|---|---|
| `op = *pc++` | `op = text(pc); pc = pc + 1` |
| `*++text = op` | `ti = ti+1; text(ti+1) = op` |
| `*++text = val` (operand) | `ti = ti+1; text(ti+1) = val` |
| `PUSH` (`*--sp = ax`) | `sp = sp-8; word_store(sp, ax)` |
| `LI` | `ax = word_load(ax)` |
| `LC` | `ax = double(mem(ax+1))` |
| `SI` | `word_store(*sp, ax); sp = sp+8` (address popped from stack) |
| `SC` | `mem(sp_addr+1) = uint8(mod(ax,256)); sp = sp+8` (low byte) |
| `LEA off` | `ax = bp + 8*off` |
| `ENT n` | `sp = sp-8; word_store(sp, bp); bp = sp; sp = sp - 8*n` |
| `ADJ n` | `sp = sp + 8*n` |
| `LEV` | `sp = bp; bp = word_load(sp); sp = sp+8; pc = word_load(sp); sp = sp+8` |
| `CALL target` | `sp = sp-8; word_store(sp, pc+1); pc = target + 1` (return = 1-based) |
| `JMP/JZ/JNZ target` | taken: `pc = target + 1`; not taken: `pc = pc + 1` (skip operand) |

`DIV`/`MOD` use `cdivmod` (C truncating division via exact double math —
MATLAB's typed `/` rounds half away from zero, which is NOT C truncation, so
the VM still needs `cdivmod` for xc.c's `a / b` / `a % b` semantics).
`SHR` is a plain `bitshift(lhs, -ax)` — the runtime's negative-count garbage
for negative lhs (BUG-11) was fixed in v1.2.39.

Helpers (both verified in the Phase 0 probe):

```matlab
function v = word_load(a)          % a = 0-based byte address, 8-aligned
    global mem
    v = typecast(mem(a+1:a+8), 'int64');   % verified correct direction
end

function word_store(a, v)          % exact for |v| < 2^53; assert beyond
    global mem
    v64 = int64(v);
    if abs(double(v64)) >= 2^53
        error('xc: value out of exact-int64 range (>2^53)');
    end
    for k = 0:7
        b = mod(v64, int64(256));      % verified
        mem(a+k+1) = uint8(b);
        v64 = (v64 - b) / int64(256);  % double quotient; exact because |v| < 2^53
        v64 = int64(v64);
    end
end
```

Alignment: globals/strings use `align8(a) = ceil(a/8)*8` (xc.c's
`(addr + sizeof(int)) & -sizeof(int)`).

## Instruction Layout Notes

- Ops with operands: `LEA(0) IMM(1) JMP(2) CALL(3) JZ(4) JNZ(5) ENT(6) ADJ(7)`
  (operand in the following text slot). `LEV(8)` and everything above: no operand.
- Syscalls (`OPEN=30 READ=31 CLOS=32 PRTF=33 MALC=34 MSET=35 MCMP=36 EXIT=37`):
  emit ONLY the opcode. The `ADJ <n>` the parser always emits right after
  (arg cleanup, `n>0`) doubles as the arg count — eval reads it as `pc[1]`
  (xc.c:1271, verified). Preserve this layout exactly.
- Jump targets: 0-based text indices (matches xc.c absolute word pointers).
- `-s` dump: on each `\n`, print `line: <source line>` then new text slots since
  the last line, `opname` + operand for ops ≤ ADJ. `opname` = 38-entry cell array.
- `-d` dump in eval: `printf('%d> %.4s ...')` → `fprintf('%d> %s ...', cycle, opname(op+1), ...)`.

## Syscall Ports

| xc.c | MATLAB |
|---|---|
| `PRTF` | read format string from `mem` until NUL → char; convert `%lld/%llu` → `%d/%u`; args from stack frame (`tmp = sp + 8*pc(2)` equivalent — args at `sp(1), sp(9), ...`); `sprintf`; print via `fprintf` |
| `OPEN` | `fopen` a path read from mem; fd = integer handle registry (cell of fids) |
| `READ` | `fread` into mem slice |
| `CLOS` | `fclose` by handle |
| `MALC` | bump allocator: `hp0 = hp; hp = hp + n; ax = hp0` (cap: heap region) |
| `MSET` | `mem(a+1:a+n) = uint8(val)` |
| `MCMP` | `memcmp` on two slices → `-1/0/1` |
| `EXIT` | return exit code from `eval` |

`PRTF` format conversion is the only place where `%` formats are rewritten;
all other syscalls are direct memory/array ops.

## Function Map (local functions in xc.m)

- `xc(varargin)` — CLI: `-s`, `-d`, file(s); load source via `fopen`+`fread`
  into `src` (char vector, NUL-terminated), `si = 0`; seed keywords + syscalls
  into symbol table exactly like xc.c main; `program()`; run `vm_eval()` from
  `idmain`; return exit code. Stack init: push `EXIT` sentinel, `PUSH tmp`,
  argc, argv-pointer, tmp (same trick — needed for `exit()` and `main` return).
  Hidden entry `xc('--vm-selftest')` runs the Phase 1 VM test battery.
- `vm_eval()` — the 38-opcode stack VM (port of xc.c `eval`; renamed to avoid
  shadowing the builtin `eval`). See the Byte↔Word Scaling Table.
- `vm_selftest()` / `run_case()` — Phase 1 hand-assembled VM tests (write
  `text`/`mem`/`sp` directly, run `vm_eval`, compare the EXIT value).
- `next()` — full lexer port: whitespace, `#` skip, idents (hash lookup),
  dec/hex/oct numbers, `//` comments, strings (`\n` escape only) into mem,
  char literals → Num, all multi-char operators, `-s` line dump hook.
- `match(tk)`, `expression(level)`, `statement()`, `enum_declaration()`,
  `function_parameter()`, `function_body()`, `function_declaration()`,
  `global_declaration()`, `program()` — direct ports; `*++text = X` → `emit(X)`;
  `a = text+1` / `*addr = text+3` → `a = ti+1` / `text(a+1) = ti+3`.

## Phases

### Phase 0: Scaffold + primitives + harness

- [x] Create `xc.m` skeleton: function signature, ALL `global` declarations,
  `fail`, `opname`, `align8`, `emit`, `word_load`, `word_store`, empty `main` body.
- [x] Create `tests/probe_primitives.m`: re-run the probe battery (typed-array
  assign, typecast load, word store round-trip, mod on int64, evalc capture of
  `fprintf`) with expected-value asserts. Gate: all pass.
- [x] Create `tests/run_tests.m`: test table + `evalc` capture + exact-diff
  compare; `run_tests` prints `PASS/FAIL` per test and total.
- [x] Probe: does `evalc` capture `fprintf` output (not just `disp`)? If not,
  harness falls back to per-test subprocess.
  **Result: yes, evalc captures fprintf — no fallback needed.**
- [x] Verify: run `tests/run_tests.m` → all PASS (28/28).
  Expected: `run_tests: N tests, N passed`.

Phase 0 notes (2026-08-10): the first gate run exposed a harness counting bug
(failures never incremented `nfail`) and primitives that did not behave as
expected; the harness now counts failures and `probe_primitives` gates the
exact primitives the port depends on, so behavior changes fail loudly before
any interpreter test runs.

### Phase 1: VM (`eval`) — all 38 opcodes

- [x] Port `eval()` with the scaling table; all arithmetic/comparison/shift
  ops on int64; `EXIT` returns `*sp`. (Implemented as `vm_eval`.)
- [x] Hand-assembled tests (write `text`/`mem`/`sp` directly, run `eval`,
  check `ax`/exit) — all 25 cases pass:
  - `IMM 1, PUSH, IMM 2, PUSH, IMM 3, MUL, ADD` → `ax == 7`
  - `IMM 7, PUSH, IMM 2, DIV` → 3; `MOD` → 1; `SUB`, shifts, bitwise, comparisons
  - `JZ`/`JNZ` loop: count 1..5, `JMP` back → exit 5
  - frame round-trip: `ENT 2, LEA 0, PUSH, IMM 42, SI, LEA 0, LI, LEV` → 42
  - `LC`/`SC` on mem bytes; `SI`/`SC` address-pop semantics
  - `CALL`/`ADJ`: callee `ENT/LEV`, caller `CALL, ADJ 1` → value round-trip
- [x] Verify: run `tests/run_tests.m` → all PASS (29/29).

Phase 1 notes (2026-08-10): pc is 1-based (`op = text(pc)`); jump operands
stay 0-based slot targets, so taken jumps set `pc = target + 1` — the scaling
table above records the corrected convention. `DIV`/`MOD` use `cdivmod`
(typed integer division isn't portable). SHR and the varargin option-scan
were originally written around two runtime quirks (BUG-11, DIV-8) that
v1.2.39 fixed; both now use the natural forms, and `probe_primitives` gates
the fixed behavior.

### Phase 2: Lexer (`next`)

- [x] Port `next()`: idents + symbol-table insert/linear-search (hash `h*147+c`,
  `strcmp` vs `symbol_names`), numbers dec/hex/oct, `//` and `#` skip, string
  literals → mem + align, char literals → Num, every operator token.
- [x] `-s` dump hook (old_src/old_text equivalents).
- [x] Tests: token-stream expectations for a sample source covering every token
  kind; string storage in mem verified via `-s`-style inspection.
- [x] Verify: run `tests/run_tests.m` → all PASS (35/35).

Phase 2 notes (2026-08-10): `next()` is a direct port — token/char codes as
doubles, `token_val` int64 for numbers (saturating like real MATLAB; corpus
literals fit int64 exactly), strings stored
byte-wise at `data` (no align yet — `align8` fires in `expression()`, Phase 3),
char literals leave the escaped value in `token_val`. `seed_symbols()` ports
main's keyword/syscall seeding (keywords Token=Char..While; syscalls
Class=Sys/Type=INT/Value=opcode; void→Char; idmain=main) and runs in the main
path before the Phase 3 parser lands. The `-s` dump prints `%d: <line>` per
newline plus new text slots since the last line; format cross-checked against
the reference build at Phase 6. Selftest: `xc('--lex-selftest')` (8 cases:
keywords, all operators, inc/dec/not/ternary, dec/hex/oct values, string bytes
+ char escapes, comment/# skip + line counting, identifier lookup, -s dump).

### Phase 3: Parser core + variables + statements

- [x] `program`, `global_declaration` (enum/fun/var), `enum_declaration`,
  `expression(level)` (units: Num, string, sizeof, Id/call, cast, `*`, `&`,
  `!`, `~`, unary ±, pre-inc/dec; binary: full precedence chain, ternary,
  assignment, `[]`), `statement` (if/else, while, `{}`, return, `;`, expr).
  The function machinery (parameter/body/declaration) was ported here too —
  the Phase 3 test list needs `main()` to run anything end-to-end.
- [x] Tests (end-to-end `xc` runs, exit codes) — all 20 pass, exit codes
  identical to the reference C build (built with gcc 15.2.0; `-s` dumps
  byte-identical modulo absolute-address jump targets):
  - `return_2.c` → exit 2 (cross-check `cc_int.m`: `movl $2, %eax` — same constant)
  - `return 1+2*3;` → 7; `return 7/2;` → 3; precedence/associativity cases
  - global `int`/`char` vars, assignments, expressions
  - if/else, while, `&&`/`||` short-circuit, ternary
  - enum declaration + use; `sizeof(int/char/ptr)`
- [x] Verify: run `tests/run_tests.m` → all PASS (60/60); `cc_int.m` path still
  green.

Phase 3 notes (2026-08-10): two porting gotchas fixed during the gate —
the C idiom `b = ++text` *reserves* a slot for jump-operand backpatching
(`slot_after()`), and `')'` is ASCII 41 (not 40). The main-return sentinel
adapts xc.c's stack trick to the two-space model: a `PUSH/EXIT` pair appended
to the text segment, with main's frame return slot pointing at it. VM bitwise
ops initially went through a byte-wise `bitop64` workaround (the runtime
corrupted the sign bit); the runtime fix landed, so the VM uses native
`bitor`/`bitxor`/`bitand` and the probe gates the behavior. `fprintf`'s
`%8.4s` width is honored but string precision `%.Ms` does not pad, so the
`-s` mnemonic column is padded manually.

### Phase 4: Functions

- [x] `function_parameter`, `function_body` (local decls + ENT), `function_declaration`,
  call emission (`CALL`/`ADJ`), symbol unwind (B* fields), recursion.
  (Ported in Phase 3 — `main()` needs the machinery; verified here.)
- [x] Tests: factorial(5)=120; fib(10)=**55** (the plan's "89" was wrong —
  89 is fib(11); cross-checked against the reference); multi-arg + char
  params; nested calls; local shadowing of globals — all 8 pass, exit codes
  identical to the reference build. Includes a local shadowing a Sys symbol
  (`printf`) to exercise the B-field unwind with non-Loc entries.
- [x] Verify: run `tests/run_tests.m` → all PASS (73/73).

Phase 4 notes (2026-08-10): no port changes were needed — the Phase 3
machinery handled recursion (factorial/fib), 4-arg calls, char params
(LC/SC path), nested calls, and both shadowing cases on the first run.
The only correction: fib(10) = 55, not 89.

### Phase 5: Pointers, arrays, casts, full expression set

- [x] `&`/`*` (LC/LI removal trick), casts, `[]` with pointer scaling,
  pointer arithmetic (+/- ×8, ptr-ptr diff ÷8), pre/post inc/dec (SC/SI),
  shifts, all bitwise ops. (Expression machinery ported in Phase 3;
  exercised here.)
- [x] Tests: swap via pointers; array sum (contiguous globals walked by a
  pointer); char* string walk + indexing; ptr-to-ptr (`**q`, Type = 1+2+2);
  `int *p = ...; p[0..2]`; cast `(char)`; `p++`/`++p` on pointers; ptr-ptr
  difference; bitwise/shift mix; `*p--` — all 12 pass, exit codes identical
  to the reference build.
- [x] Verify: run `tests/run_tests.m` → all PASS (85/85).

Phase 5 notes (2026-08-10): no port changes — the Phase 3 expression
machinery handled the whole pointer corpus on the first run. Dialect
constraints confirmed: no local/global initializers (`int *p = &a;` fails —
declare then assign), and locals grow the frame *down* (so `p++` walking
locals is implementation-dependent — the corpus walks contiguous globals,
which grow up). `int**` = Type 1+2+2 = 5; each deref subtracts PTR (2).

### Phase 6: Syscalls + full parity

- [x] PRTF (format read + `%lld→%d` conversion + arg frame), OPEN/READ/CLOS,
  MALC (bump), MSET/MCMP, EXIT — all eight syscalls implemented; the ADJ
  operand doubles as the arg count (`tmp = sp + 8*n`, `tmp[-k]` = args).
- [x] `-s` and `-d` smoke tests (dump shapes sane) — `-s` verified
  byte-identical to the reference (modulo absolute jump addresses) in Phase
  3; `-d` trace lines asserted in the suite.
- [x] Acceptance: `tests/programs/hello.c` — exact stdout diff vs reference:
  `fibonacci( 0) = 1` … `fibonacci(10) = 89` — byte-identical (incl. the
  `exit(0)` suffix with no trailing newline). hello.c is in the suite with
  its full expected output.
- [x] Verify: run `tests/run_tests.m` → all PASS (94/94, full suite).

Phase 6 notes (2026-08-10): PRTF pulls up to 8 resolved args from the frame
and passes them to `sprintf` individually (mixed `%s` strings and numerics).
OPEN/READ/CLOS use a small fd registry; `sys_read` reads directly with
`fread(fid, cnt)` (EOF-correct since the runtime fix — no content cache).
MALC is a bump allocator from `data` (the compiled-data end) capped at
2·poolsize. hello.c's original `/* */` header comment was replaced with `//`
comments — the reference dialect only supports `//` (the port itself now
supports both).

### Phase 7: Cleanup

- [x] Remove probe temp files; final README pass; full suite re-run (95/95).
- [x] Append any newly found runtime bugs to the bug report (BUG-16/17/18,
  DIV-10 from Phase 6).

Phase 7 notes (2026-08-10): README updated to reflect the completed
interpreter (no more "planned"; dialect notes added); all scratch files
removed; the acceptance and every corpus program verified against the
reference C build. The port is feature-complete — remaining work is the GPL2
adoption noted under Attribution.

## Verification

Every phase: run `tests/run_tests.m` (batched — one invocation covers the
phase's tests). Full acceptance at Phase 6 compares `hello.c` output
byte-for-byte. `cc_int.m` regression: run the assembly track after reorg (see
README) — `gcc` is available at `C:\msys64\ucrt64\bin\gcc.exe`.

## Risks

| Risk | Mitigation |
|---|---|
| Primitive behavior gaps | Probe gate in Phase 0 re-verifies every primitive the port depends on before each test run |
| Shared state across functions | Port uses `global` variables (verified working) |
| int64 overflow semantics | Decision: follow real MATLAB — int64 arithmetic saturates at INT64_MAX/MIN, it never wraps. Unreachable in practice: `word_store` guards \|v\| < 2^53 and the corpus is small. VM DIV/MOD keep C truncation (they implement the interpreted language), computed via exact double math (`cdivmod`) |
| Precision ≥ 2^53 | `word_store` asserts; test values small |
| Performance (interpreted eval) | Fine for hello.c-scale; fib(10) ≈ few thousand VM ops |
| `evalc` misses `fprintf` | Phase 0 probe; fallback: subprocess per test |

## Attribution / Licensing

`xc.m` is a derivative port of `xc.c` (lotabout/write-a-C-interpreter, GPL2,
itself derived from c4). `tests/programs/hello.c` copied from the same repo with
attribution. The project is licensed under the GNU GPL version 2 (`LICENSE`,
added 2026-08-15); `xc.m`/`cc_int.m` carry GPL notice headers.

## Post-parity (2026-08-10)

Features beyond the reference dialect, added after full parity, all covered
by the suite (208/208):

| Feature | Design |
|---|---|
| `/* */` comments | lexer skip to `*/`; newlines inside reuse the `-s` dump/line handler (`nl_line`); unterminated → error |
| `%s` in PRTF | format scan resolves each `%...s` arg (an address) to its mem string; specs are kept, so width/precision/truncation work; mixed args passed individually via a preallocated cell |
| Array declarations | `int a[N];` global (N·8 bytes at data) and local (ceil(N·elem/8) frame slots); `Type += ARRAY_FLAG (0x1000)`; the Id unit emits the address without a load (decay to pointer); `&a` becomes a no-op; `a[i]`, `*p`, `f(a)` all work |
| Initializers | `const_expr()`: Num, ±Num, char literal, string address, enum constant. Globals: stored at data before the 8-byte stride. Locals: buffered `[slot, value, is_char]` and emitted after ENT (LEA/PUSH/IMM/SI|SC) |
| Array initializers | `int a[N] = {c0, c1, ...};` global (mem/word_store byte writes) and local (buffered, per-element stores emitted after ENT; char elements via LEA/PUSH/IMM/ADD/PUSH/IMM/SC); char arrays also via `char s[N] = "str"`; shorter lists zero-filled (C semantics), too-long lists error |
| `void` functions | new Void token (165) for the seed; `void f() { return; }` parses (bare `return;` already worked); `void` variables rejected |
| `(void)` / array params | `void f(void)` declares zero parameters; `int f(int a[3])` / `char s[]` decay to pointers (`Type += PTR`), the caller already passes array addresses |
| Multi-dim arrays | dims parsed in a loop; per-level byte strides stored per-symbol (`array_strides`), carried through expressions as `bstrides`; `a[i]` of a multi-dim array is an address (no load), `a[i][j]` loads; Add/Sub/Brak scale by the current stride; `sizeof(a)` = total bytes (symbol column 10) |
| Non-const local inits | ENT emitted first with a placeholder frame size, backpatched after all locals are counted; initializers emit inline after ENT (any expression). Global inits stay compile-time constants (targeted error) |
| printf length modifiers | PRTF normalizes the format: length modifiers (`h l j z t L`) stripped before the conversion char, so `%ls`/`%ld`/`%hd`/`%llu` become plain `%s`/`%d`/`%u`; string literals NUL-terminated in mem so consecutive literals don't bleed (the reference relied on zeroed pages) |
| `sizeof` exprs | `sizeof(arr)` (column-10 total), `sizeof(int/char/ptr)`, `sizeof(<expr>)` parsed for its type and the emitted code discarded |
| Nested-brace inits | `parse_braces(dims, lvl)` — recursive brace groups fill sub-arrays, scalars continue flat, groups cover the remainder of their subobject (C 6.7.9 brace elision); used by global and local array initializers |
| Non-const global inits | balanced token-skip at declaration (no emission) records {addr, source pos, is_char}; after program() a startup prologue re-parses each expression (IMM addr/PUSH/expr/SI|SC) and ends with JMP main; entry pc starts at the prologue |
| `%n` / `%p` | per-spec output build: numeric specs via single-spec sprintf (safe), `%s` width/precision applied manually (`fmt_str_spec` — sprintf with string args repeats the format, BUG-16), `%n` word_stores the running count, `%p` prints lowercase hex (`hex_addr`) |
| `%*` width | each `*` in a spec consumes an extra arg, substituted numerically into the spec (`%*d` + 5 → `%5d`; negative width becomes the `-` flag) |
| `sizeof` rows | `barr`/`barr_size` state: array-valued expressions report their byte size (bare name = total; a multi-dim `a[i]` = the consumed stride, so `sizeof(a[0])` = 24) |
| pointer-to-subarray | `&` prepends the current sub-array size to the strides (`&a` → [total …], `&a[0]` → [row …]); plain parens keep the array state |
| Multi-read READ | `sys_read` uses `fread(fid, cnt)` directly — the runtime stops at EOF and advances the file position, so repeated reads work |

Still unsupported (documented): array initializers, array/void parameters,
multi-dimension arrays, non-constant initializers.
