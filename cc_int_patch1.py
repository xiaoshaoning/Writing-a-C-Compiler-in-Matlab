# -*- coding: utf-8 -*-
# re-apply cc_int.m double-support edits (batch 1: lexer/types/literals)
BS = chr(92); t = BS + 't'
TAB = chr(9)
p = 'src/cc_int.m'
s = open(p, encoding='utf-8').read()

def rep(old, new, ctx):
    global s
    n = s.count(old)
    assert n >= 1, ctx + " count=%d" % n
    s = s.replace(old, new, 1)

# 1) main globals
rep("global src si token token_val idname strtext out fname lbl lvars lvartype ...\n"
    "       lvararr fbytes funcs fret called retlbl cfn globals gtype garr glist ...\n"
    "       strs nstr etype ltype cret loopctx stags sdefs nstid estruc ...\n"
    "       lvarstruct gstruct typedefs enums lvarstride gstride bstride glabels sret sretsize libfns libcalls ginit",
    "global src si token token_val token_dval token_isflt idname strtext out fname lbl lvars lvartype ...\n"
    "       lvararr fbytes funcs fret called retlbl cfn globals gtype garr glist ...\n"
    "       strs nstr etype ltype cret loopctx stags sdefs nstid estruc ...\n"
    "       lvarstruct gstruct typedefs enums lvarstride gstride bstride glabels sret sretsize libfns libcalls ginit fptypes libargt",
    "main globals")

# 2) init + libfns
rep("token_val = 0;\nstrtext = [];",
    "token_val = 0;\ntoken_dval = 0;      % the double value of a float literal\ntoken_isflt = 0;     % 1 when the current Num is a float (double) literal\nstrtext = [];",
    "init")

rep("""libfns.close = '_close';
libcalls = struct();""",
    """libfns.close = '_close';
% math intrinsics (double).  The shim name is __cc_<name>_<nargs>; the
% simulator (x86sim) emulates them with MATLAB math.  libargt records the
% declared parameter types (6 = double) so call sites promote int args.
libfns.sin = 'sin';     libfns.cos = 'cos';    libfns.tan = 'tan';
libfns.asin = 'asin';   libfns.acos = 'acos';  libfns.atan = 'atan';
libfns.sinh = 'sinh';   libfns.cosh = 'cosh';  libfns.tanh = 'tanh';
libfns.exp = 'exp';     libfns.log = 'log';    libfns.log10 = 'log10';
libfns.sqrt = 'sqrt';   libfns.fabs = 'fabs';  libfns.floor = 'floor';
libfns.ceil = 'ceil';   libfns.trunc = 'trunc'; libfns.round = 'round';
libfns.cbrt = 'cbrt';
libfns.fmod = 'fmod';   libfns.pow = 'pow';    libfns.fmin = 'fmin';
libfns.fmax = 'fmax';   libfns.atan2 = 'atan2';
libargt = struct();
libargt.sin = 6; libargt.cos = 6; libargt.tan = 6;
libargt.asin = 6; libargt.acos = 6; libargt.atan = 6;
libargt.sinh = 6; libargt.cosh = 6; libargt.tanh = 6;
libargt.exp = 6; libargt.log = 6; libargt.log10 = 6;
libargt.sqrt = 6; libargt.fabs = 6; libargt.floor = 6;
libargt.ceil = 6; libargt.trunc = 6; libargt.round = 6;
libargt.cbrt = 6;
libargt.fmod = [6 6]; libargt.pow = [6 6];
libargt.fmin = [6 6]; libargt.fmax = [6 6]; libargt.atan2 = [6 6];
fptypes = struct();   % user function -> vector of parameter type codes
libcalls = struct();""",
    "libfns/libargt")

# 3) lexer float literals
rep("""if c >= '0' && c <= '9'
    v = int64(0);
    while si <= numel(src) && src(si) >= '0' && src(si) <= '9'
        v = v * int64(10) + int64(double(src(si)) - 48);
        si = si + 1;
    end
    token = 128;                % Num
    token_val = v;
    return;""",
    """if c >= '0' && c <= '9'
    isflt = 0;
    sstart = si;
    while si <= numel(src) && src(si) >= '0' && src(si) <= '9'
        si = si + 1;
    end
    if si <= numel(src) && src(si) == 46   % '.'
        isflt = 1;
        si = si + 1;
        while si <= numel(src) && src(si) >= '0' && src(si) <= '9'
            si = si + 1;
        end
    end
    if si <= numel(src) && (src(si) == 101 || src(si) == 69)  % e E
        p = si + 1;
        if p <= numel(src) && (src(p) == 43 || src(p) == 45)
            p = p + 1;
        end
        dig = 0;
        while p <= numel(src) && src(p) >= '0' && src(p) <= '9'
            p = p + 1;
            dig = 1;
        end
        if dig
            isflt = 1;
            si = p;
        end
    end
    if isflt
        d = str2double(char(src(sstart:si-1)));
        token = 128;                 % Num
        token_val = typecast(d, 'int64');   % the IEEE bit pattern
        token_dval = d;
        token_isflt = 1;
        return;
    end
    v = int64(0);
    for k = sstart:si-1
        v = v * int64(10) + int64(double(src(k)) - 48);
    end
    token = 128;                % Num
    token_val = v;
    token_isflt = 0;
    return;""",
    "lexer float")

# 4) double keyword
rep("""    elseif strcmp(id, 'unsigned')
        token = 188;            % Unsigned
    else""",
    """    elseif strcmp(id, 'unsigned')
        token = 188;            % Unsigned
    elseif strcmp(id, 'double')
        token = 189;            % Double
    else""",
    "double kw")
rep("""    token = 128;                % Num
    token_val = int64(v);
    return;""",
    """    token = 128;                % Num
    token_val = int64(v);
    token_isflt = 0;
    return;""",
    "char lit isflt")

# 5) parse_basetype + struct members
rep("""elseif token == 188         % unsigned (int): a 64-bit unsigned type
    base = 5;
    next();
    if token == 131         % 'unsigned int'
        next();
    end
elseif token == 178         % struct""",
    """elseif token == 188         % unsigned (int): a 64-bit unsigned type
    base = 5;
    next();
    if token == 131         % 'unsigned int'
        next();
    end
elseif token == 189         % double
    base = 6;
    next();
elseif token == 178         % struct""",
    "basetype double")
rep("""    elseif token == 134     % char
        mbase = 1;
        next();
    elseif token == 178     % struct""",
    """    elseif token == 134     % char
        mbase = 1;
        next();
    elseif token == 189     % double
        mbase = 6;
        next();
    elseif token == 178     % struct""",
    "struct member double")

# 6) parse_arr_init float fail
rep("""            if token ~= 128
                fail('expected a constant array initializer');
            end
            v = double(token_val);
            next();""",
    """            if token ~= 128
                fail('expected a constant array initializer');
            end
            if token_isflt
                % float patterns need exact 64-bit emission; the shared
                % numeric path cannot hold them (double arrays lose bits
                % beyond 2^53).  Runtime stores (assignment/expressions)
                % are the supported way to fill double arrays today.
                fail('float literal array initializers are not supported');
            end
            v = double(token_val);
            next();""",
    "arr_init float fail")

# 7) parse_function_tail ptypes + fptypes
rep("[nparams, psize] = parse_params(rettype >= 1000);",
    "[nparams, psize, ptypes] = parse_params(rettype >= 1000);",
    "ptypes call")
rep("fparams.(fname2) = psize;   % the caller's per-arg copy sizes",
    "fparams.(fname2) = psize;   % the caller's per-arg copy sizes\nfptypes.(fname2) = ptypes;  % the caller's per-arg type codes (codegen)",
    "fptypes store")
rep("function [nparams, psize] = parse_params(returns_struct)",
    "function [nparams, psize, ptypes] = parse_params(returns_struct)",
    "parse_params sig")
rep("""psize = zeros(1, nparams);
for k = 1:nparams
    psize(k) = sizes{k};
end
end""",
    """psize = zeros(1, nparams);
ptypes = zeros(1, nparams);
for k = 1:nparams
    psize(k) = sizes{k};
    ptypes(k) = types{k};
end
end""",
    "parse_params ptypes")

# 8) parse_globals float init
rep("""global token idname strtext globals gtype garr gstruct glist gstride gvararrsz out ginit""",
    """global token idname strtext globals gtype garr gstruct glist gstride gvararrsz out ginit token_isflt token_dval""",
    "globals global")
rep("""            if token == 128
                initv = double(token_val);
                next();
                if neg
                    initv = -initv;
                end
            elseif ~neg""",
    """            if token == 128
                if token_isflt
                    % float literal: keep the exact IEEE pattern.  Stored
                    % as {'F', uint64} so emit_globals can print exact hex.
                    pat = typecast(token_dval, 'uint64');
                    next();
                    if neg
                        pat = bitxor(pat, uint64(9223372036854775808));
                    end
                    initv = {'F', pat};
                else
                    initv = double(token_val);
                    next();
                    if neg
                        initv = -initv;
                    end
                end
            elseif ~neg""",
    "globals float init")

# 9) emit_globals
rep("""        elseif iscell(v) && strcmp(v{1}, 'B')""",
    """        elseif iscell(v) && strcmp(v{1}, 'F')
            % double scalar initializer: exact 64-bit IEEE pattern
            em(sprintf('""" + TAB + """.quad""" + TAB + """0x%016X', v{2}));
        elseif iscell(v) && strcmp(v{1}, 'B')""",
    "emit globals F")
rep("""        elseif t == 1
            em(sprintf('""" + TAB + """.byte""" + TAB + """%d', v));
        else
            em(sprintf('""" + TAB + """.quad""" + TAB + """%d', v));
        end""",
    """        elseif t == 1
            em(sprintf('""" + TAB + """.byte""" + TAB + """%d', v));
        elseif t == 6
            % an int constant initializer for a double global: promote
            em(sprintf('""" + TAB + """.quad""" + TAB + """0x%016X', typecast(double(v), 'uint64')));
        else
            em(sprintf('""" + TAB + """.quad""" + TAB + """%d', v));
        end""",
    "emit globals t6")

# 10) parse_statement declaration dispatch + sizeof + cast peek
rep("""if token == 131 || token == 134 || token == 178 || token == 188 || ...  % int/char/struct/unsigned
   (token == 150 && isfield(typedefs, idname))            % typedef'd type
    parse_declaration();""",
    """if token == 131 || token == 134 || token == 178 || token == 188 || ...  % int/char/struct/unsigned
   token == 189 || ...                                          % double
   (token == 150 && isfield(typedefs, idname))            % typedef'd type
    parse_declaration();""",
    "stmt dispatch")
rep("""    is_cast = (token == 131 || token == 134 || token == 178 || token == 187 || ...
              (token == 150 && isfield(typedefs, idname)));""",
    """    is_cast = (token == 131 || token == 134 || token == 178 || token == 187 || ...
              token == 189 || ...
              (token == 150 && isfield(typedefs, idname)));""",
    "cast peek")
rep("""    if token == 131 || token == 134 || token == 178   % a type""",
    """    if token == 131 || token == 134 || token == 178 || token == 189   % a type""",
    "sizeof")

# parse_unary globals line
rep("""global token token_val idname strtext lvars lvartype lvararr lvarstruct ...
       globals gtype garr gstruct funcs fret frettype fparams called ltype libfns libcalls ...
       etype estruc lvarstride gstride bstride lvararrsz gvararrsz curarrsz si typedefs fbytes""",
    """global token token_val token_dval token_isflt idname strtext lvars lvartype lvararr lvarstruct ...
       globals gtype garr gstruct funcs fret frettype fparams called ltype libfns libcalls ...
       etype estruc lvarstride gstride bstride lvararrsz gvararrsz curarrsz si typedefs fbytes fptypes libargt""",
    "unary globals")

open(p, 'w', encoding='utf-8').write(s)
print("batch 1 OK")