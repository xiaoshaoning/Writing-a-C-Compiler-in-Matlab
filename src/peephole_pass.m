function lines2 = peephole_pass(lines)
% peephole_pass — optimization plan Phase B: safe local rewrites on the
% emitted instruction list (docs/2026-08-16-compiler-optimization-plan.md).
%  1. `jmp .L` directly followed by `.L:` — the jump is a no-op (falls
%     through to its own target): drop the jmp.
%  2. instructions after an unconditional `jmp`, up to the next label, are
%     unreachable: drop them.
%  3. `movq $N, %rax` immediately followed by `addq/subq/imulq $M, %rax`
%     — fold into `movq $N op $M, %rax` (constant-index array scaling).
%  4. `jcc .L1; jmp .L2; .L1:` — invert the condition and jump to .L2
%     directly (the intermediate jmp becomes unreachable).
%  5. `leaq K(%rbp), %rax; movq (%rax), %rax` (also movzbl/movsbl and the
%     `name(%rip)` global form) — the address is pure overhead: fold to
%     `movq K(%rbp), %rax`.
%  6. `movq $N, %rax; movq %rax, mem` — fold to `movq $N, mem`.
%  7. `leaq K(%rbp), %rax; addq $N, %rax` — fold N into the displacement:
%     `leaq K+N(%rbp), %rax` (constant-index array addressing).
%  8. `cmpq A; setcc %al; movzbl %al, %eax; cmpq $0, %rax; je/jne .L` —
%     the normalize-then-test chain is dead (the 0/1 value is consumed
%     only by the branch): keep the first cmpq and branch directly with
%     the mapped condition (je inverts, jne keeps the sense). The movzbl
%     does not set flags, so the second cmpq was load-bearing — this is
%     the fold that makes it removable.
%  9. the operand juggle: `pushq %rax; <simple right>; movq %rax, %rbx;
%     popq %rax; op %rbx, %rax` — the left is still in rax after the
%     pushq (a push does not clobber it), so the spill/restore round-trip
%     is dead: `movq $N, %rbx; op %rbx, %rax` (also the mem loads and
%     movzbl/movsbl byte rights). 5 instructions become 2.
% 10. store-address spill: `pushq %rax; <rhs>; popq %rbx; movq %rax,
%     (%rbx)` — the store-LHS address rides in %r8 instead of the stack
%     (`movq %rax, %r8; <rhs>; movq %rax, (%r8)`), guarded by a call/
%     push/store/r8 barrier (nested assignments keep the outer spill).
% 11. `subq $0, %rsp` — the frame allocation of a function with no
%     locals is a no-op (the rsp already equals rbp).
% Runs to a fixed point (removing a jmp can expose more dead code). Only
% instruction lines are ever touched: labels and directives are preserved.
% Flags semantics are respected — setcc/movzbl chains are left alone (a
% movzbl does not set flags, so a following cmpq is never redundant).
% Every line is processed as a double code vector (the clone mangles
% string literals matching internal names — `exit`, `sum`, … — when they
% cross local-function boundaries); char() rebuilds them at the end.
for k = 1:numel(lines)
    lines{k} = double(lines{k});
end
for it = 1:8
    [lines, changed] = pp_once(lines);
    if ~changed
        break;
    end
end
lines2 = {};
for k = 1:numel(lines)
    lines2{end+1} = char(lines{k});
end
end

function [lines2, changed] = pp_once(lines)
n = numel(lines);
changed = 0;
del = zeros(1, n);          % 1 = drop this line
foldmap = cell(1, n);       % index -> replacement line ([] = none)
labat = cell(1, n);         % label name at this index ([] if not a label)
for k = 1:n
    ln = lines{k};
    if ~isempty(ln) && ln(end) == 58          % ':'
        labat{k} = ln(1:end-1);
    end
end
for k = 1:n
    if del(k), continue; end
    ln = lines{k};
    if ~pp_isinstr(ln)
        continue;
    end
    [mnem, arg1] = pp_parts(ln);
    % --- 5. load-side address fold: leaq X, %rax ; movq (%rax), %rax ---
    if pp_eq(mnem, 'leaq')
        [m5, o1, o2] = pp_ops(ln);
        if pp_eq(o2, '%rax') && (pp_memrbp(o1) || pp_memrip(o1)) && ...
           k < n && pp_isinstr(lines{k+1})
            [lm, lo1, lo2] = pp_ops(lines{k+1});
            if (pp_eq(lm, 'movq') || pp_eq(lm, 'movzbl') || pp_eq(lm, 'movsbl')) && ...
               pp_eq(lo1, '(%rax)') && (pp_eq(lo2, '%rax') || pp_eq(lo2, '%eax'))
                foldmap{k} = [9, double(lm), 9, o1, 44, 32, double(lo2)]; % ', '
                del(k+1) = 1;
                changed = 1;
                continue;
            end
        end
    end
    % --- 6. immediate store: movq $N, %rax ; movq %rax, mem ---
    if pp_eq(mnem, 'movq') && k < n && pp_isinstr(lines{k+1})
        [m6, o1, o2] = pp_ops(ln);
        if numel(o1) >= 2 && o1(1) == 36 && pp_eq(o2, '%rax')   % '$'
            [s6, so1, so2] = pp_ops(lines{k+1});
            if pp_eq(s6, 'movq') && pp_eq(so1, '%rax') && ...
               (pp_memrbp(so2) || pp_memrip(so2))
                foldmap{k} = [9, double('movq'), 9, o1, 44, 32, double(so2)];
                del(k+1) = 1;
                changed = 1;
                continue;
            end
        end
    end
    % --- 7. constant-offset fold: leaq K(%rbp), %rax ; addq $N, %rax ---
    if pp_eq(mnem, 'leaq') && k < n && pp_isinstr(lines{k+1})
        [m7, o1, o2] = pp_ops(ln);
        if pp_eq(o2, '%rax') && pp_memrbp(o1)
            [a7, ao1, ao2] = pp_ops(lines{k+1});
            if pp_eq(a7, 'addq') && numel(ao1) >= 2 && ao1(1) == 36 && pp_eq(ao2, '%rax')
                kdisp = pp_disp(o1);
                nv = str2double(char(ao1(2:end)));
                if ~isnan(kdisp) && ~isnan(nv) && abs(kdisp + nv) < 2^31
                    nd = kdisp + nv;
                    if nd == 0
                        disp2 = double('(%rbp)');
                    else
                        disp2 = [double(num2str(nd)), double('(%rbp)')];
                    end
                    foldmap{k} = [9, double('leaq'), 9, disp2, 44, 32, double('%rax')];
                    del(k+1) = 1;
                    changed = 1;
                    continue;
                end
            end
        end
    end
    % --- 9. operand-juggle fold (E1: keep the left in rax, right in rbx) ---
    if pp_eq(mnem, 'pushq') && pp_eq(arg1, '%rax') && k + 4 <= n
        [r9, ro1, ro2] = pp_ops(lines{k+1});
        [m9, mo1, mo2] = pp_ops(lines{k+2});
        [p9, po1, po2] = pp_ops(lines{k+3});
        [o9, oo1, oo2] = pp_ops(lines{k+4});
        simple = (pp_eq(r9, 'movq') && pp_eq(ro2, '%rax')) || ...
                 ((pp_eq(r9, 'movzbl') || pp_eq(r9, 'movsbl')) && pp_eq(ro2, '%eax'));
        if simple && pp_eq(m9, 'movq') && pp_eq(mo1, '%rax') && pp_eq(p9, 'popq') && ...
           pp_eq(po1, '%rax') && (pp_eq(mo2, '%rbx') || pp_eq(mo2, '%rcx'))
            if pp_eq(ro2, '%rax')
                ndest = double('%rbx');
            else
                ndest = double('%ebx');
            end
            tailok = 0;
            if pp_eq(mo2, '%rbx')
                % arithmetic / compare tail: op %rbx, %rax, or the div/mod
                % tail: cqto; idivq %rbx (or xorq %rdx,%rdx; divq %rbx)
                if pp_isop(o9) && pp_eq(oo1, '%rbx') && pp_eq(oo2, '%rax')
                    tailok = 1;
                elseif k + 5 <= n
                    [d5, do1, do2] = pp_ops(lines{k+5});
                    if (pp_eq(o9, 'cqto') && pp_eq(d5, 'idivq')) || ...
                       (pp_eq(o9, 'xorq') && pp_eq(d5, 'divq'))
                        tailok = 2;
                    end
                end
            elseif pp_eq(mo2, '%rcx')
                % shift tail: shlq/sarq/shrq %cl, %rax — the count
                % destination follows the right operand's width: %ecx for
                % byte loads (movzbl/movsbl need a 32-bit dest), %rcx for
                % word loads
                if pp_eq(o9, 'shlq') || pp_eq(o9, 'sarq') || pp_eq(o9, 'shrq')
                    if pp_eq(oo1, '%cl') && pp_eq(oo2, '%rax')
                        tailok = 1;
                        if pp_eq(ro2, '%rax')
                            ndest = double('%rcx');
                        else
                            ndest = double('%ecx');
                        end
                    end
                end
            end
            if tailok == 1
                foldmap{k} = [9, double(r9), 9, ro1, 44, 32, ndest];
                del(k+1) = 1;
                del(k+2) = 1;
                del(k+3) = 1;
                changed = 1;
                continue;
            elseif tailok == 2
                % div/mod: the juggle lines die; cqto/idivq stay as-is
                foldmap{k} = [9, double(r9), 9, ro1, 44, 32, ndest];
                del(k+1) = 1;
                del(k+2) = 1;
                del(k+3) = 1;
                changed = 1;
                continue;
            end
        end
    end
    % --- 10. store-address spill: pushq %rax; <rhs>; popq %rbx;
    % movq %rax, (%rbx)  ->  movq %rax, %r8; <rhs>; movq %rax, (%r8)
    % r8 is dead in the expression codegen (only the shims touch it), so
    % the lhs address can ride there instead of the stack — but only when
    % the rhs makes no call (a shim call would clobber r8).
    if pp_eq(mnem, 'pushq') && pp_eq(arg1, '%rax') && k < n
        j = k + 1;
        depth = 1;
        hascall = 0;
        anypush = 0;
        hasstore = 0;
        popat = -1;
        while j <= n
            if ~isempty(labat{j})
                break;
            end
            if pp_isinstr(lines{j})
                [jm, jo1, jo2] = pp_ops(lines{j});
                if pp_eq(jm, 'movq') && (pp_eq(jo2, '(%rbx)') || pp_eq(jo1, '(%rbx)'))
                    hasstore = 1;       % a nested spill store: r8 is taken
                end
                if pp_hasr8(jo1) || pp_hasr8(jo2)
                    hasstore = 1;       % r8 already in use below: bail
                end
                if pp_eq(jm, 'pushq')
                    anypush = 1;        % a nested spill or call arg: bail
                    depth = depth + 1;
                elseif pp_eq(jm, 'popq')
                    depth = depth - 1;
                    if depth == 0
                        popat = j;
                        break;
                    end
                elseif pp_eq(jm, 'addq') && numel(jo1) >= 2 && jo1(1) == 36 && ...
                       pp_eq(jo2, '%rsp')
                    depth = depth - floor(str2double(char(jo1(2:end))) / 8);
                elseif pp_eq(jm, 'call')
                    hascall = 1;
                end
            end
            j = j + 1;
        end
        if popat > 0 && popat + 1 <= n && ~hascall && ~anypush && ~hasstore
            [st, sto1, sto2] = pp_ops(lines{popat+1});
            if pp_eq(st, 'movq') && pp_eq(sto1, '%rax') && pp_eq(sto2, '(%rbx)')
                foldmap{k} = [9, double('movq'), 9, double('%rax, %r8')];
                del(popat) = 1;
                foldmap{popat+1} = [9, double('movq'), 9, double('%rax, (%r8)')];
                changed = 1;
                continue;
            end
        end
    end
    % --- 8. setcc-normalize-then-branch fold ---
    if pp_eq(mnem, 'cmpq') && k + 4 <= n
        [s8, so1, so2] = pp_ops(lines{k+1});
        if pp_issetcc(s8) && pp_eq(so1, '%al')
            [z8, zo1, zo2] = pp_ops(lines{k+2});
            [q8, qo1, qo2] = pp_ops(lines{k+3});
            [j8, jo1, jo2] = pp_ops(lines{k+4});
            if pp_eq(z8, 'movzbl') && pp_eq(zo1, '%al') && pp_eq(zo2, '%eax') && ...
               pp_eq(q8, 'cmpq') && pp_eq(qo1, '$0') && pp_eq(qo2, '%rax') && ...
               (pp_eq(j8, 'je') || pp_eq(j8, 'jne')) && numel(jo1) >= 1
                foldmap{k+1} = [9, pp_setcc2jcc(s8, j8), 9, jo1];
                del(k+2) = 1;
                del(k+3) = 1;
                del(k+4) = 1;
                changed = 1;
                continue;
            end
        end
    end
    % --- 3. immediate fold: movq $N, %rax ; addq/subq/imulq $M, %rax ---
    if (pp_eq(mnem, 'addq') || pp_eq(mnem, 'subq') || pp_eq(mnem, 'imulq')) && ...
       numel(arg1) >= 2 && arg1(1) == 36 && k > 1 && ~del(k-1)   % '$'
        prev = lines{k-1};
        [pmnem, parg1] = pp_parts(prev);
        if pp_isinstr(prev) && pp_eq(pmnem, 'movq') && numel(parg1) >= 2 && ...
           parg1(1) == 36 && numel(parg1) >= 3
            pv = str2double(char(parg1(2:end-1)));
            v = str2double(char(arg1(2:end-1)));
            if ~isnan(pv) && ~isnan(v)
                if pp_eq(mnem, 'addq'), nv = pv + v;
                elseif pp_eq(mnem, 'subq'), nv = pv - v;
                else nv = pv * v; end
                if abs(nv) < 2^53
                    del(k-1) = 1;
                    foldmap{k} = [9, 109 111 118 113 9 36, double(num2str(nv)), ...
                                  44 32 37 114 97 120];   % 'movq	$NV, %rax'
                    changed = 1;
                    continue;
                end
            end
        end
    end
    % --- 4. jcc .L1; jmp .L2; .L1: — collapse to the inverted condition
    % jumping straight to .L2. The inverted jcc's fall-through then lands
    % on .L1's code, and the intermediate jmp is unreachable. Valid only
    % when .L1 is the very next line (the code between is empty).
    if pp_isjcc(mnem) && k + 2 <= n && pp_isinstr(lines{k+1}) && ...
       ~isempty(labat{k+2}) && cv_eq(labat{k+2}, arg1)
        [m2, a2] = pp_parts(lines{k+1});
        if pp_eq(m2, 'jmp')
            foldmap{k} = [9, pp_invjcc(mnem), 9, a2];
            del(k+1) = 1;               % the jmp becomes unreachable
            changed = 1;
            continue;
        end
    end
    % --- 11. empty-frame no-op: subq $0, %rsp ---
    if pp_eq(mnem, 'subq') && pp_eq(arg1, '$0, %rsp')
        del(k) = 1;
        changed = 1;
        continue;
    end
    % --- 1+2. unconditional jmp: its own target as the next label, and
    % any instructions between it and the next label are unreachable ---
    if pp_eq(mnem, 'jmp')
        j = k + 1;
        while j <= n
            if ~isempty(labat{j})
                if cv_eq(labat{j}, arg1)
                    del(k) = 1;         % jmp to its own next label
                    changed = 1;
                end
                break;
            end
            if pp_isinstr(lines{j})
                del(j) = 1;             % unreachable instruction
                changed = 1;
            end
            j = j + 1;
        end
    end
end
lines2 = {};
for k = 1:n
    if del(k), continue; end
    if ~isempty(foldmap{k})
        lines2{end+1} = foldmap{k};
    else
        lines2{end+1} = lines{k};
    end
end
end

function b = pp_isinstr(ln)
% pp_isinstr — a line is an instruction if it is tab-led (9) and its
% second code is not '.' (46); directives are tab-led dots, labels have
% no leading tab.
b = numel(ln) >= 2 && ln(1) == 9 && ln(2) ~= 46;
end

function [mnem, arg1] = pp_parts(ln)
% pp_parts — split a tab-led line into mnemonic and first argument
% (both code vectors).
t = find(ln == 9);
if numel(t) >= 3
    mnem = ln(2:t(2)-1);
    arg1 = ln(t(2)+1:t(3)-1);
elseif numel(t) == 2
    mnem = ln(2:t(2)-1);
    arg1 = ln(t(2)+1:end);
elseif numel(t) == 1
    mnem = ln(2:end);
    arg1 = [];
else
    mnem = [];
    arg1 = [];
end
end

function [mnem, op1, op2] = pp_ops(ln)
% pp_ops — split a tab-led instruction line into mnemonic, first operand
% and second operand (code vectors; op2 = [] when there is no second
% operand). Operands are comma-separated in the emitted assembly.
[mnem, rest] = pp_parts2(ln);
if isempty(rest)
    op1 = [];
    op2 = [];
    return;
end
c = find(rest == 44);                       % ','
if isempty(c)
    op1 = rest;
    op2 = [];
else
    op1 = rest(1:c-1);
    op2 = rest(c+2:end);                    % skip ', '
end
end

function [mnem, rest] = pp_parts2(ln)
% pp_parts2 — mnemonic and the remainder of the line after it.
t = find(ln == 9);
if numel(t) >= 2
    mnem = ln(2:t(2)-1);
    rest = ln(t(2)+1:end);
elseif numel(t) == 1
    mnem = ln(2:end);
    rest = [];
else
    mnem = [];
    rest = [];
end
end

function b = pp_memrbp(op)
% pp_memrbp — does the operand end with '(%rbp)' (a frame slot)?
b = numel(op) >= 6 && cv_eq(op(end-5:end), double('(%rbp)'));
end

function b = pp_hasr8(op)
% pp_hasr8 — does the operand reference %r8 (the store-spill register)?
b = pp_contains(op, double('%r8'));
end

function b = pp_memrip(op)
% pp_memrip — does the operand reference name(%rip) (a global)?
b = pp_contains(op, double('%rip'));
end

function b = pp_contains(hay, needle)
% pp_contains — code-vector substring test. (The clone's strfind rejects
% numeric arrays, so search manually.)
b = 0;
if numel(needle) > numel(hay)
    return;
end
for k = 1:numel(hay) - numel(needle) + 1
    if cv_eq(hay(k:k+numel(needle)-1), needle)
        b = 1;
        return;
    end
end
end

function v = pp_disp(op)
% pp_disp — the displacement of a K(%rbp) operand (0 for '(%rbp)').
p = find(op == 40);                         % '('
if isempty(p)
    v = NaN;
    return;
end
if p == 1
    v = 0;
else
    v = str2double(char(op(1:p-1)));
end
end

function b = pp_issetcc(mnem)
% pp_issetcc — setcc mnemonics this pass can fold into a branch.
b = pp_eq(mnem, 'setl') || pp_eq(mnem, 'setg') || pp_eq(mnem, 'setle') || ...
    pp_eq(mnem, 'setge') || pp_eq(mnem, 'sete') || pp_eq(mnem, 'setne') || ...
    pp_eq(mnem, 'seta') || pp_eq(mnem, 'setae') || pp_eq(mnem, 'setb') || ...
    pp_eq(mnem, 'setbe');
end

function b = pp_isop(mnem)
% pp_isop — binary ops emitted as `op %rbx, %rax` on the juggled operands.
b = pp_eq(mnem, 'addq') || pp_eq(mnem, 'subq') || pp_eq(mnem, 'imulq') || ...
    pp_eq(mnem, 'andq') || pp_eq(mnem, 'orq') || pp_eq(mnem, 'xorq') || ...
    pp_eq(mnem, 'cmpq');
end

function s = pp_setcc2jcc(cc, br)
% pp_setcc2jcc — the branch that replaces a setcc+test+branch chain.
% `je` branches when the tested value is zero, i.e. when the setcc
% condition is FALSE — so it inverts; `jne` keeps the condition's sense.
if pp_eq(br, 'je')
    if pp_eq(cc, 'setl'), s = double('jge');
    elseif pp_eq(cc, 'setg'), s = double('jle');
    elseif pp_eq(cc, 'setle'), s = double('jg');
    elseif pp_eq(cc, 'setge'), s = double('jl');
    elseif pp_eq(cc, 'sete'), s = double('jne');
    elseif pp_eq(cc, 'setne'), s = double('je');
    elseif pp_eq(cc, 'seta'), s = double('jbe');
    elseif pp_eq(cc, 'setae'), s = double('jb');
    elseif pp_eq(cc, 'setb'), s = double('jae');
    else s = double('ja'); end               % setbe
else
    if pp_eq(cc, 'setl'), s = double('jl');
    elseif pp_eq(cc, 'setg'), s = double('jg');
    elseif pp_eq(cc, 'setle'), s = double('jle');
    elseif pp_eq(cc, 'setge'), s = double('jge');
    elseif pp_eq(cc, 'sete'), s = double('je');
    elseif pp_eq(cc, 'setne'), s = double('jne');
    elseif pp_eq(cc, 'seta'), s = double('ja');
    elseif pp_eq(cc, 'setae'), s = double('jae');
    elseif pp_eq(cc, 'setb'), s = double('jb');
    else s = double('jbe'); end              % setbe
end
end

function b = pp_eq(a, s)
% pp_eq — code-vector equality with a literal (the literal stays inside
% this helper, so it is never mangled by the clone).
b = cv_eq(a, double(s));
end

function b = cv_eq(a, b)
% cv_eq — code-vector equality (clone-safe).
b = numel(a) == numel(b) && all(a == b);
end

function b = pp_isjcc(mnem)
% pp_isjcc — branch-condition mnemonics this pass can invert.
b = pp_eq(mnem, 'je') || pp_eq(mnem, 'jne') || pp_eq(mnem, 'jl') || ...
    pp_eq(mnem, 'jle') || pp_eq(mnem, 'jg') || pp_eq(mnem, 'jge') || ...
    pp_eq(mnem, 'jb') || pp_eq(mnem, 'jbe') || pp_eq(mnem, 'ja') || ...
    pp_eq(mnem, 'jae');
end

function s = pp_invjcc(mnem)
% pp_invjcc — the inverted branch condition (a code vector).
if pp_eq(mnem, 'je'), s = double('jne');
elseif pp_eq(mnem, 'jne'), s = double('je');
elseif pp_eq(mnem, 'jl'), s = double('jge');
elseif pp_eq(mnem, 'jge'), s = double('jl');
elseif pp_eq(mnem, 'jg'), s = double('jle');
elseif pp_eq(mnem, 'jle'), s = double('jg');
elseif pp_eq(mnem, 'jb'), s = double('jae');
elseif pp_eq(mnem, 'jae'), s = double('jb');
elseif pp_eq(mnem, 'ja'), s = double('jbe');
else s = double('ja'); end
end
