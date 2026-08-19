# -*- coding: utf-8 -*-
# cc_int.m double-support edits, batch 3: relational, ternary, assignment, incdec
BS = chr(92); t = BS + 't'
p = 'src/cc_int.m'
s = open(p, encoding='utf-8').read()

def rep(old, new, ctx):
    global s
    n = s.count(old)
    assert n >= 1, ctx + " count=%d" % n
    s = s.replace(old, new, 1)

# ---- relational: double comparisons with NaN-safe setcc ----
rep("""    op = token;
    sav_etype = etype;
    next();
    em('""" + t + """pushq""" + t + """%rax');
    parse_shift();
    em('""" + t + """movq""" + t + """%rax, %rbx');
    em('""" + t + """popq""" + t + """%rax');
    em('""" + t + """cmpq""" + t + """%rbx, %rax');
    if op == 144        % Lt""",
    """    op = token;
    sav_etype = etype;
    next();
    em('""" + t + """pushq""" + t + """%rax');
    parse_shift();
    rhs_t = etype;
    em('""" + t + """movq""" + t + """%rax, %rbx');
    em('""" + t + """popq""" + t + """%rax');
    if sav_etype == 6 || rhs_t == 6
        % double comparison: ucomisd a, b compares b-a; flags ZF (eq),
        % CF (b < a), PF (unordered/NaN).  C semantics: NaN comparisons
        % are false except !=; only < and <= need the !PF guard.
        if sav_etype == 6 && rhs_t == 6
            em('""" + t + """movq""" + t + """%rax, %xmm0');
            em('""" + t + """movq""" + t + """%rbx, %xmm1');
        elseif sav_etype == 6
            em('""" + t + """movq""" + t + """%rax, %xmm0');
            em('""" + t + """cvtsi2sdq""" + t + """%rbx, %xmm1');
        else
            em('""" + t + """cvtsi2sdq""" + t + """%rax, %xmm0');
            em('""" + t + """movq""" + t + """%rbx, %xmm1');
        end
        em('""" + t + """ucomisd""" + t + """%xmm1, %xmm0');
        if op == 144        % Lt: CF && !PF
            em('""" + t + """setb""" + t + """%al');
            em('""" + t + """setnp""" + t + """%cl');
            em('""" + t + """andb""" + t + """%cl, %al');
        elseif op == 145    % Gt: CF=0 && ZF=0
            em('""" + t + """seta""" + t + """%al');
        elseif op == 146    % Le: (CF || ZF) && !PF
            em('""" + t + """setbe""" + t + """%al');
            em('""" + t + """setnp""" + t + """%cl');
            em('""" + t + """andb""" + t + """%cl, %al');
        else                % Ge: CF=0
            em('""" + t + """setae""" + t + """%al');
        end
        em('""" + t + """movzbl""" + t + """%al, %eax');
        etype = 0;
    else
        em('""" + t + """cmpq""" + t + """%rbx, %rax');
        if op == 144        % Lt""",
    "relational head")
rep("""    em('""" + t + """movzbl""" + t + """%al, %eax');
    etype = 0;
end
end""",
    """    em('""" + t + """movzbl""" + t + """%al, %eax');
    etype = 0;
    end
end
end""",
    "relational tail")

# ---- ternary ----
rep("""    parse_assignment();
    if token == 58          % ':'
        next();
    else
        fail('missing colon in conditional');
    end
    em(sprintf('""" + t + """jmp""" + t + """%s', e));
    em(sprintf('%s:', f));
    parse_conditional();
    em(sprintf('%s:', e));
    etype = 0;
end
end""",
    """    parse_assignment();
    t1 = etype;
    if token == 58          % ':'
        next();
    else
        fail('missing colon in conditional');
    end
    em(sprintf('""" + t + """jmp""" + t + """%s', e));
    em(sprintf('%s:', f));
    parse_conditional();
    t2 = etype;
    em(sprintf('%s:', e));
    if t1 == 6 || t2 == 6
        etype = 6;      % a double branch promotes the result
    else
        etype = 0;
    end
end
end""",
    "ternary")

# ---- assignment '=' conversion ----
rep("""    if op == 61             % plain '='
        em('""" + t + """pushq""" + t + """%rax');
        next();
        parse_assignment();
        em('""" + t + """popq""" + t + """%rbx');""",
    """    if op == 61             % plain '='
        em('""" + t + """pushq""" + t + """%rax');
        next();
        parse_assignment();
        rhs_t = etype;      % the RHS expression's type
        em('""" + t + """popq""" + t + """%rbx');
        if sav_ltype == 6 && rhs_t ~= 6
            % double lvalue, int RHS: promote before the store
            em('""" + t + """cvtsi2sdq""" + t + """%rax, %xmm0');
            em('""" + t + """movq""" + t + """%xmm0, %rax');
        elseif rhs_t == 6 && sav_ltype ~= 1 && sav_ltype ~= 6
            % int/pointer lvalue, double RHS: truncate toward zero
            em('""" + t + """movq""" + t + """%rax, %xmm0');
            em('""" + t + """cvttsd2siq""" + t + """%xmm0, %rax');
        end""",
    "assign = conv")

# ---- incdec ----
rep("""if t == 1
    em('""" + t + """movzbl""" + t + """(%rax), %eax');
else
    em('""" + t + """movq""" + t + """(%rax), %rax');
end
if post
    em('""" + t + """movq""" + t + """%rax, %rbx');   % old value = the postfix result
end
if op == 170
    em(sprintf('""" + t + """addq""" + t + """$%d, %%rax', scale));
else
    em(sprintf('""" + t + """subq""" + t + """$%d, %%rax', scale));
end""",
    """if t == 1
    em('""" + t + """movzbl""" + t + """(%rax), %eax');
else
    em('""" + t + """movq""" + t + """(%rax), %rax');
end
if post
    em('""" + t + """movq""" + t + """%rax, %rbx');   % old value = the postfix result
end
if t == 6
    % double ++/-- : add/sub 1.0 in SSE
    em('""" + t + """movq""" + t + """%rax, %xmm0');
    em('""" + t + """movabsq""" + t + """$0x3FF0000000000000, %rbx');   % 1.0
    em('""" + t + """movq""" + t + """%rbx, %xmm1');
    if op == 170
        em('""" + t + """addsd""" + t + """%xmm1, %xmm0');
    else
        em('""" + t + """subsd""" + t + """%xmm1, %xmm0');
    end
    em('""" + t + """movq""" + t + """%xmm0, %rax');
elseif op == 170
    em(sprintf('""" + t + """addq""" + t + """$%d, %%rax', scale));
else
    em(sprintf('""" + t + """subq""" + t + """$%d, %%rax', scale));
end""",
    "incdec")

open(p, 'w', encoding='utf-8').write(s)
print("batch 3 OK")