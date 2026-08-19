# -*- coding: utf-8 -*-
# cc_int.m double-support edits, batch 2: operators, casts, calls, incdec
BS = chr(92); t = BS + 't'
p = 'src/cc_int.m'
s = open(p, encoding='utf-8').read()

def rep(old, new, ctx):
    global s
    n = s.count(old)
    assert n >= 1, ctx + " count=%d" % n
    s = s.replace(old, new, 1)

# ---- Num literal (double) in parse_unary ----
rep("""elseif token == 128         % Num
    em(sprintf('""" + t + """movq""" + t + """$%d, %%rax', double(token_val)));
    etype = 0;
    estruc = 0;
    next();""",
    """elseif token == 128         % Num
    if token_isflt
        % a double literal: movabsq $0x<pattern>, %rax.  The exact
        % 64-bit hex form is parsed exactly by x86sim (sim_num64); the
        % ordinary decimal form would lose precision for large patterns.
        em(sprintf('""" + t + """movabsq""" + t + """$0x%016X, %%rax', ...
            mod(double(typecast(token_dval, 'uint64')), 18446744073709551616)));
        etype = 6;
    else
        em(sprintf('""" + t + """movq""" + t + """$%d, %%rax', double(token_val)));
        etype = 0;
    end
    estruc = 0;
    next();""",
    "Num literal")

# ---- casts ----
rep("""    is_cast = (token == 131 || token == 134 || token == 178 || token == 187 || ...
              token == 189 || ...
              (token == 150 && isfield(typedefs, idname)));""",
    """    is_cast = (token == 131 || token == 134 || token == 178 || token == 187 || ...
              token == 189 || ...
              (token == 150 && isfield(typedefs, idname)));""",
    "cast peek (idempotent)")

rep("""        else
            parse_unary();      % the operand (cast-expression = unary)
            if cbase == 1 && cdepth == 0
                em('""" + t + """movsbl""" + t + """%al, %eax');   % truncate to a signed char
            end
            etype = cbase + 2 * cdepth;
            estruc = 0;
        end""",
    """        else
            parse_unary();      % the operand (cast-expression = unary)
            if cbase == 6 && cdepth == 0
                % (double)x: int/char -> double via cvtsi2sdq
                if etype ~= 6
                    em('""" + t + """cvtsi2sdq""" + t + """%rax, %xmm0');
                    em('""" + t + """movq""" + t + """%xmm0, %rax');
                end
            elseif (cbase == 0 || cbase == 5) && cdepth == 0 && etype == 6
                % (int)x / (unsigned)x: double -> int (truncate toward 0)
                em('""" + t + """movq""" + t + """%rax, %xmm0');
                em('""" + t + """cvttsd2siq""" + t + """%xmm0, %rax');
            elseif cbase == 1 && cdepth == 0
                em('""" + t + """movsbl""" + t + """%al, %eax');   % truncate to a signed char
            end
            etype = cbase + 2 * cdepth;
            estruc = 0;
        end""",
    "casts")

# ---- prefix ops ----
rep("""for k = numel(ops):-1:1
    op = ops(k);
    if op == 45             % '-'
        em('""" + t + """negq""" + t + """%rax');
    elseif op == 126        % '~'
        em('""" + t + """notq""" + t + """%rax');
    elseif op == 33         % '!': logical not — eax = (eax == 0)
        em('""" + t + """cmpq""" + t + """$0, %rax');
        em('""" + t + """sete""" + t + """%al');
        em('""" + t + """movzbl""" + t + """%al, %eax');""",
    """for k = numel(ops):-1:1
    op = ops(k);
    if op == 45 && etype == 6     % '-' on a double: flip the sign bit
        em('""" + t + """movabsq""" + t + """$0x8000000000000000, %rbx');
        em('""" + t + """xorq""" + t + """%rbx, %rax');
    elseif op == 45             % '-' on an integer
        em('""" + t + """negq""" + t + """%rax');
    elseif op == 126        % '~'
        em('""" + t + """notq""" + t + """%rax');
    elseif op == 33 && etype == 6   % '!' on a double: (d == 0.0)
        % ucomisd: ZF set for equal (incl. +-0); NaN is unordered (ZF=0)
        em('""" + t + """movabsq""" + t + """$0, %rbx');
        em('""" + t + """movq""" + t + """%rax, %xmm0');
        em('""" + t + """movq""" + t + """%rbx, %xmm1');
        em('""" + t + """ucomisd""" + t + """%xmm1, %xmm0');
        em('""" + t + """sete""" + t + """%al');
        em('""" + t + """movzbl""" + t + """%al, %eax');
        etype = 0;
    elseif op == 33         % '!': logical not — eax = (eax == 0)
        em('""" + t + """cmpq""" + t + """$0, %rax');
        em('""" + t + """sete""" + t + """%al');
        em('""" + t + """movzbl""" + t + """%al, %eax');""",
    "prefix ops")

# ---- call-site argument promotion ----
rep("""        nargs = 0;
        if token ~= 41      % ')'
            while true
                parse_assignment();""",
    """        nargs = 0;
        if token ~= 41      % ')'
            while true
                parse_assignment();
                at = etype;
                % declared parameter type: promote int -> double or
                % truncate double -> int at the call boundary (C function
                % prototype semantics).  User functions use fptypes;
                % math intrinsics carry libargt.  Varargs (no entry) are
                % passed through untouched (bit patterns).
                dt = [];
                if isfield(fptypes, name) && nargs + 1 <= numel(fptypes.(name))
                    dt = fptypes.(name)(nargs + 1);
                elseif isfield(libargt, name) && nargs + 1 <= numel(libargt.(name))
                    dt = libargt.(name)(nargs + 1);
                end
                if ~isempty(dt) && dt == 6 && at ~= 6
                    em('""" + t + """cvtsi2sdq""" + t + """%rax, %xmm0');
                    em('""" + t + """movq""" + t + """%xmm0, %rax');
                elseif ~isempty(dt) && dt ~= 6 && at == 6
                    em('""" + t + """movq""" + t + """%rax, %xmm0');
                    em('""" + t + """cvttsd2siq""" + t + """%xmm0, %rax');
                end""",
    "call arg conv")

# ---- additive ----
rep("""    em('""" + t + """pushq""" + t + """%rax');
    parse_term();
    rhs_t = etype;
    em('""" + t + """movq""" + t + """%rax, %rbx');
    em('""" + t + """popq""" + t + """%rax');
    if t >= 2               % the left is a pointer""",
    """    em('""" + t + """pushq""" + t + """%rax');
    parse_term();
    rhs_t = etype;
    em('""" + t + """movq""" + t + """%rax, %rbx');
    em('""" + t + """popq""" + t + """%rax');
    if t == 6 || rhs_t == 6
        % double arithmetic: usual arithmetic conversions (int -> double)
        if t == 6 && rhs_t == 6
            em('""" + t + """movq""" + t + """%rax, %xmm0');
            em('""" + t + """movq""" + t + """%rbx, %xmm1');
        elseif t == 6
            em('""" + t + """movq""" + t + """%rax, %xmm0');
            em('""" + t + """cvtsi2sdq""" + t + """%rbx, %xmm1');
        else
            em('""" + t + """cvtsi2sdq""" + t + """%rax, %xmm0');
            em('""" + t + """movq""" + t + """%rbx, %xmm1');
        end
        if op == 43
            em('""" + t + """addsd""" + t + """%xmm1, %xmm0');
        else
            em('""" + t + """subsd""" + t + """%xmm1, %xmm0');
        end
        em('""" + t + """movq""" + t + """%xmm0, %rax');
        etype = 6;
    elseif t >= 2               % the left is a pointer""",
    "additive")

# ---- term ----
rep("""    em('""" + t + """pushq""" + t + """%rax');
    parse_unary();
    em('""" + t + """movq""" + t + """%rax, %rbx');
    em('""" + t + """popq""" + t + """%rax');
    if op == 42
        em('""" + t + """imulq""" + t + """%rbx, %rax');
    elseif sav_etype == 5""",
    """    em('""" + t + """pushq""" + t + """%rax');
    parse_unary();
    rhs_t = etype;
    em('""" + t + """movq""" + t + """%rax, %rbx');
    em('""" + t + """popq""" + t + """%rax');
    if sav_etype == 6 || rhs_t == 6
        % double multiplication/division (usual arithmetic conversions)
        if op == 37
            fail('%% on doubles is not supported');
        end
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
        if op == 42
            em('""" + t + """mulsd""" + t + """%xmm1, %xmm0');
        else
            em('""" + t + """divsd""" + t + """%xmm1, %xmm0');
        end
        em('""" + t + """movq""" + t + """%xmm0, %rax');
        etype = 6;
    elseif op == 42
        em('""" + t + """imulq""" + t + """%rbx, %rax');
    elseif sav_etype == 5""",
    "term")
rep("""    else
        em('""" + t + """cqto');
        em('""" + t + """idivq""" + t + """%rbx');
        if op == 37
            em('""" + t + """movq""" + t + """%rdx, %rax');
        end
    end
    etype = 0;
end
end""",
    """    else
        em('""" + t + """cqto');
        em('""" + t + """idivq""" + t + """%rbx');
        if op == 37
            em('""" + t + """movq""" + t + """%rdx, %rax');
        end
    end
    if sav_etype ~= 6 && rhs_t ~= 6
        etype = 0;
    end
end
end""",
    "term etype tail")

# ---- equality ----
rep("""    em('""" + t + """pushq""" + t + """%rax');
    parse_relational();
    em('""" + t + """movq""" + t + """%rax, %rbx');
    em('""" + t + """popq""" + t + """%rax');
    em('""" + t + """cmpq""" + t + """%rbx, %rax');
    if op == 148
        em('""" + t + """sete""" + t + """%al');
    else
        em('""" + t + """setne""" + t + """%al');
    end
    em('""" + t + """movzbl""" + t + """%al, %eax');
    etype = 0;
end
end""",
    """    em('""" + t + """pushq""" + t + """%rax');
    parse_relational();
    rhs_t = etype;
    em('""" + t + """movq""" + t + """%rax, %rbx');
    em('""" + t + """popq""" + t + """%rax');
    if etype == 6 || rhs_t == 6
        % double equality: NaN is unordered (ZF=0) so == is false and
        % != is true, exactly matching C.
        if etype == 6 && rhs_t == 6
            em('""" + t + """movq""" + t + """%rax, %xmm0');
            em('""" + t + """movq""" + t + """%rbx, %xmm1');
        elseif etype == 6
            em('""" + t + """movq""" + t + """%rax, %xmm0');
            em('""" + t + """cvtsi2sdq""" + t + """%rbx, %xmm1');
        else
            em('""" + t + """cvtsi2sdq""" + t + """%rax, %xmm0');
            em('""" + t + """movq""" + t + """%rbx, %xmm1');
        end
        em('""" + t + """ucomisd""" + t + """%xmm1, %xmm0');
        if op == 148
            em('""" + t + """sete""" + t + """%al');
        else
            em('""" + t + """setne""" + t + """%al');
        end
        em('""" + t + """movzbl""" + t + """%al, %eax');
        etype = 0;
    else
        em('""" + t + """cmpq""" + t + """%rbx, %rax');
        if op == 148
            em('""" + t + """sete""" + t + """%al');
        else
            em('""" + t + """setne""" + t + """%al');
        end
        em('""" + t + """movzbl""" + t + """%al, %eax');
        etype = 0;
    end
end
end""",
    "equality")

open(p, 'w', encoding='utf-8').write(s)
print("batch 2 OK")