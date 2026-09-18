function bad = check_globals(fname)
% check_globals - static audit of file-global declarations in a .m file.
%
%   bad = check_globals('src/cc_int.m')
%
% Returns a cell array of human-readable violations, empty when the file
% is clean. A violation is a function that reads a name which is declared
% `global` somewhere in the file but not in that function, *before* it
% assigns the name locally. On real MATLAB (isolated function scopes) that
% read is an "Unrecognized function or variable" error; on the lenient
% clones it resolves through the caller chain and hides. See
% docs/2026-09-07-x86sim-peephole-divergences.md for the 19 instances this
% found in cc_int.m (fixed in 7db5dfe / 5ed841d).
%
% A first touch that is an assignment is NOT reported: it makes the name a
% function-local on real MATLAB (function outputs named like globals, local
% computations), which is legal. Name-based and conservative by design --
% it can miss a shadowing local, but it does not fire on legal code, so a
% clean result is meaningful.
%
% Flat representation and per-line word extraction: nested-cell growth
% (`c{i}{end+1}`) silently no-ops on the clones, and scanning every global
% name against every line is ~20x slower than this inverted form.

fid = fopen(fname, 'r');
if fid < 0
    error(sprintf('check_globals: could not open(%s)', fname));
end
s = char(fread(fid, inf, 'uint8')');
fclose(fid);

[Lno, Ltxt] = cg_lines(s);
n = numel(Ltxt);

fileglob = {};
for k = 1:n
    g = cg_global_names(Ltxt{k});
    for j = 1:numel(g)
        if ~cg_cellhas(fileglob, g{j})
            fileglob{end+1} = g{j};
        end
    end
end
fgs = cg_strset(fileglob);

% function ranges: (start, stop, name), flat arrays
ra = []; rb = []; rn = {};
fstart = [];
for k = 1:n
    if cg_isfunc(Ltxt{k})
        fstart(end+1) = k;
    end
end
if isempty(fstart)
    ra = 1; rb = n; rn = {'(main)'};
else
    ra(1) = 1; rb(1) = fstart(1) - 1; rn{1} = '(main)';
    for i = 1:numel(fstart)
        ra(end+1) = fstart(i);
        if i < numel(fstart)
            rb(end+1) = fstart(i+1) - 1;
        else
            rb(end+1) = n;
        end
        rn{end+1} = cg_funcname(Ltxt{fstart(i)});
    end
end

bad = {};
for i = 1:numel(ra)
    if ra(i) > rb(i)
        continue;               % empty (e.g. the pre-function main chunk)
    end
    declared = {};
    for j = ra(i):rb(i)
        g = cg_global_names(Ltxt{j});
        for q = 1:numel(g)
            if ~cg_cellhas(declared, g{q})
                declared{end+1} = g{q};
            end
        end
    end
    ds = cg_strset(declared);
    done = struct();
    for q = ra(i):rb(i)
        code = cg_strip(Ltxt{q});
        words = cg_words(code);
        for w = 1:numel(words)
            nm = words{w};
            if isfield(done, nm) || ~isfield(fgs, nm) || isfield(ds, nm)
                continue;
            end
            done.(nm) = 1;
            pos = cg_wordpos(code, nm);
            if ~isempty(pos) && ~cg_iswrite(code, nm, pos(1))
                bad{end+1} = sprintf('%s @%d reads global ''%s'' without declaring it', ...
                    rn{i}, Lno(q), nm);
            end
        end
    end
end
end

% --------------------------------------------------------------------------
function s = cg_strset(names)
% cg_strset - a struct whose fields are the names, for O(1) membership.
s = struct();
for k = 1:numel(names)
    s.(names{k}) = 1;
end
end

function [nos, txts] = cg_lines(s)
% cg_lines - physical lines -> logical lines (source line numbers kept),
% joining `...` continuations.
d = double(s);
start = 1;
lineno = 1;
rno = []; rtxt = {};
for i = 1:numel(d)
    if d(i) == 10 || d(i) == 13
        if i > start
            rno(end+1) = lineno;
            rtxt{end+1} = char(d(start:i-1));
        end
        if d(i) == 10
            lineno = lineno + 1;
        end
        start = i + 1;
    end
end
if start <= numel(d)
    rno(end+1) = lineno;
    rtxt{end+1} = char(d(start:end));
end
nos = []; txts = {};
k = 1;
while k <= numel(rtxt)
    txt = rtxt{k};
    first = rno(k);
    while numel(txt) >= 3 && strcmp(txt(end-2:end), '...')
        txt = [txt(1:end-3), ' '];
        k = k + 1;
        if k <= numel(rtxt)
            txt = [txt, rtxt{k}];
        end
    end
    nos(end+1) = first;
    txts{end+1} = txt;
    k = k + 1;
end
end

function out = cg_strip(line)
% cg_strip - blank out single-quoted strings and % comments.
d = double(line);
instr = 0;
i = 1;
while i <= numel(d)
    c = d(i);
    if instr
        if c == 39
            if i < numel(d) && d(i+1) == 39
                d(i) = 32; d(i+1) = 32; i = i + 2; continue;
            end
            instr = 0; d(i) = 32;
        else
            d(i) = 32;
        end
    else
        if c == 39
            instr = 1; d(i) = 32;
        elseif c == 37
            d(i:end) = 32;
            break;
        end
    end
    i = i + 1;
end
out = char(d);
end

function names = cg_global_names(line)
names = {};
t = strtrim(cg_strip(line));
if numel(t) < 7 || ~strcmp(t(1:6), 'global') || cg_iswordchar(t(7))
    return;
end
names = cg_words(t(7:end));
end

function b = cg_isfunc(line)
t = strtrim(cg_strip(line));
b = 0;
if numel(t) >= 8 && strcmp(t(1:8), 'function')
    if numel(t) == 8 || ~cg_iswordchar(t(9))
        b = 1;
    end
end
end

function nm = cg_funcname(line)
nm = '(anon)';
t = strtrim(cg_strip(line));
i = 9;
while i <= numel(t) && t(i) == 32, i = i + 1; end
if i <= numel(t) && t(i) == '['
    cl = find(t == ']', 1);
    if ~isempty(cl), i = cl + 1; end
    while i <= numel(t) && t(i) == 32, i = i + 1; end
    if i <= numel(t) && t(i) == 61, i = i + 1; end
    while i <= numel(t) && t(i) == 32, i = i + 1; end
end
j = i;
while j <= numel(t) && cg_iswordchar(t(j)), j = j + 1; end
if j > i
    nm = t(i:j-1);
end
end

function names = cg_words(s)
names = {};
i = 1;
while i <= numel(s)
    if cg_iswordchar(s(i)) && (i == 1 || ~cg_iswordchar(s(i-1)))
        j = i;
        while j <= numel(s) && cg_iswordchar(s(j)), j = j + 1; end
        names{end+1} = s(i:j-1);
        i = j;
    else
        i = i + 1;
    end
end
end

function b = cg_iswordchar(c)
b = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || ...
    (c >= 97 && c <= 122) || c == 95;
end

function b = cg_cellhas(c, s)
b = 0;
for k = 1:numel(c)
    if strcmp(c{k}, s)
        b = 1;
        return;
    end
end
end

function pos = cg_wordpos(code, name)
% cg_wordpos - start indices of `name` as a whole word in code.
pos = [];
n = numel(name);
i = 1;
while i <= numel(code) - n + 1
    if strcmp(code(i:i+n-1), name)
        before = (i == 1) || ~cg_iswordchar(code(i-1));
        after = (i+n > numel(code)) || ~cg_iswordchar(code(i+n));
        if before && after
            pos(end+1) = i;
        end
        i = i + n;
    else
        i = i + 1;
    end
end
end

function b = cg_iswrite(code, name, p)
% cg_iswrite - is the occurrence of `name` at p an assignment target?
% Accepts name =, name(i) =, name{i} =, name.f = and the [ .. name .. ] =
% output-list form; a comparison (==, <=, >=, ~=) is not a write.
b = 0;
i = p + numel(name);
while true                        % skip indexing / field suffixes
    while i <= numel(code) && code(i) == 32, i = i + 1; end
    if i <= numel(code) && (code(i) == '(' || code(i) == '{')
        op = code(i);
        if op == '(', cl = ')'; else cl = '}'; end
        depth = 0;
        while i <= numel(code)
            if code(i) == op, depth = depth + 1; end
            if code(i) == cl
                depth = depth - 1;
                if depth == 0, i = i + 1; break; end
            end
            i = i + 1;
        end
    elseif i <= numel(code) && code(i) == 46
        i = i + 1;
        while i <= numel(code) && cg_iswordchar(code(i)), i = i + 1; end
    else
        break;
    end
end
while i <= numel(code) && code(i) == 32, i = i + 1; end
if i <= numel(code) && code(i) == 61 && ~(i < numel(code) && code(i+1) == 61)
    b = 1;
end
if ~b && p > 1 && any(code(1:p-1) == '[') && any(code(p:end) == ']')
    rb = find(code(p:end) == ']', 1) + p - 1;
    j = rb + 1;
    while j <= numel(code) && code(j) == 32, j = j + 1; end
    if j <= numel(code) && code(j) == 61
        b = 1;
    end
end
end
