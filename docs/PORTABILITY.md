# Portability rules

This code runs on three MATLAB implementations, and **every bug that survived a green test run
was a difference between them**. Not one was a logic error. So the rules below are not
style advice; each is a defect that shipped, or nearly did, and each costs a session when it is
rediscovered.

The three are:

| | |
|---|---|
| **real MATLAB** (R2024b) | the authority. Refuses things the other two accept. |
| **the development runtime** (`$MATLAB`, a MATLAB-compatible CLI) | fast enough to run the suite; accepts most of what MATLAB refuses. |
| **the C clone** (`$MATLAB` too, at `MATLAB_in_C/release/`) | the oracle for cross-checks. Accepts illegal syntax the others refuse. |

Neither of the last two is a subset of the other: each accepts things the other refuses. That
is why **one green run proves nothing about portability**, and why the comparison is
automated:

```
CC_RUNTIMES="$ENGINE;$CLONE" bash tests/run_all.sh          # diff the failure sets
CC_SECTIONS=none CC_RUNTIMES="$A;$B" bash tests/run_all.sh  # ...in a minute
```

It compares the *failure sets*, not the counts: two runtimes can each fail one test, both
report "1 failed", and be failing different tests.

## Rules

| # | Don't | Why | Guarded by |
|---|---|---|---|
| 1 | take an exit status at face value | real MATLAB returns the full status (`5467`, `988156804`); the OS reports the low byte. Compare `mod(st, 256)` | corpus exit-code checks |
| 2 | use `sscanf`'s 4th output, or trust its first | the clone implements neither: a `%[...]`-only first conversion returns a **string**, so `[parts, count]` silently concatenated the name and the count | plain scanning everywhere |
| 3 | use `regexp(..., 'end')` or `regexp(..., 'split')` | `'end'` returns empty; `'split'` on a newline returns the whole text as ONE line, so a 338-program corpus reads as 1 | plain character scanning |
| 4 | name a struct field that does not start with a letter | `@anon3`, `__st1_n`, `.byte` are accepted by both clones and refused by MATLAB: `字段名称 ".byte" 无效`. Three separate defects | `tests/check_field_names.m`, self-tested |
| 5 | write `struct('f', {})` or `struct('f', {cellvalue})` | the first is a **1-element struct** on the clone; the second is a struct **array** with one element per cell entry, so `it.ops` throws "Dot indexing is not supported" | cells of structs; assign cell fields after construction |
| 6 | assign to a chained target: `a{i}.f = v` or `a.(s){end+1} = v` | the clone accepts, the engine refuses with "indexed assignment base must be a variable" | temporaries; `push_item()` in `ma_asm.m` |
| 7 | grow a struct array with `t(end+1) = struct(...)` | corrupts it on the clone: three rows became four and every `.name` returned the new one. Silent | write the rows into the table literal |
| 8 | hand an absolute path to `system()` | the engine rejects it ("can't create ...: Invalid argument") | relative paths in the working directory |
| 9 | carry a 64-bit value in a double, or rely on `uint64` | a double holds 53 bits, so `$9223372036854775807` assembled to a different number at the right length; `uint64` conversions diverge between builds | `decimal_bytes`/`hexval` read digits, no numeric type |
| 10 | compare two captured strings with `strcmp` | an empty capture is a different **type** on R2024b, so `strcmp('','')` is 1 on the clones and errors on MATLAB | `same_text()` compares through `char` |
| 11 | treat data as code | indexing a char array whose value was `exit` or `quit` **terminated the interpreter**, silently. Found from `call exit` in a corpus program; fixed upstream at `b648ecb` | not guarded; keep runtime current (see below) |

## Keeping a runtime current

Rule 11 was fixed upstream and still reproduced locally for two days, because `dist/` held a
binary older than the fix and a running process had locked it. **Read the pin, don't assume
it.** `docs/PROJECT_STATUS.md` names the installed build; a stale one makes every engine result
describe an engine nobody else has.

## Adding a rule

Two forms, both cheap:

- a **probe check** in `tests/probe_*.m` when the difference is observable at runtime;
- a **static check** over `src/*.m` when it is not - rules 4 and 8 are of that kind, and a
  green run on the lenient runtimes can never find them. Static checks carry a synthetic
  violation so a broken checker cannot pass silently.
