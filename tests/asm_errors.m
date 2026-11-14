function [pass, fail] = asm_errors()
% asm_errors - inputs the assembler MUST refuse, each with a message that names the cause.
%
% These are the cases where a wrong answer would be silent rather than loud: `shlq %al,%rax`
% encoded as `shlq %cl,%rax` (a different instruction), `movabsq` with a 17-digit literal
% truncated to the low 64 bits, `jmp %rsi` reported as "unresolved symbol" with an empty
% name. A refusal is only half the job, so each case asserts on the CAUSE and not merely on
% something having been thrown - a message that names the symptom of its own missing feature
% is how a real bug becomes a test expectation.
%
% Only ma_asm is called: no as, no objcopy, no gcc. This therefore runs on a machine with no
% binutils, which is where the byte gate cannot run at all.

tab = char(9);
bs = char(92);
cases = {
    'unknown mnemonic',        [tab 'fooq %rax'],                          'unknown mnemonic fooq'
    'unresolved branch',       [tab 'jmp nowhere'],                        'unresolved symbol nowhere'
    'malformed operand',       [tab 'movq (%rax, %rbx'],                  'unbalanced parentheses'
    'shift by a wrong reg',    [tab 'shlq %al, %rax'],                     'the count must be an immediate or %cl'
    'sse in a gpr operation',  [tab 'addq %xmm0, %rax'],                   'does not take an SSE register'
    'immediate wider than 64', [tab 'movabsq $0x10000000000000000, %rax'], 'more than 16 hex digits'
    'label and instruction',   ['L1: ' tab 'ret'],                         'a label and an instruction on one line'
    'indirect jump',           [tab 'jmp %rsi'],                           'indirect jmp is not supported'
    'comm without a size',     [tab '.comm' tab 'x'],                      '.comm needs a name and a size'
    'string ending in a backslash', [tab '.string' tab '"abc' bs],         '.string ends in a backslash'
};

pass = 0;
fail = 0;
for k = 1:size(cases, 1)
    try
        ma_asm(cases{k, 2});
        fail = fail + 1;
        fprintf('FAIL  asm should refuse: %s\n', cases{k, 1});
    catch e
        if ~isempty(strfind(e.message, cases{k, 3}))
            pass = pass + 1;
        else
            fail = fail + 1;
            fprintf('FAIL  asm refusal message: %s\n', cases{k, 1});
            fprintf('        wanted "%s"\n        got    "%s"\n', cases{k, 3}, e.message);
        end
    end
end
end
