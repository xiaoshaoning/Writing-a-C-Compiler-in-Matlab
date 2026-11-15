function bad = check_field_names(f)
% check_field_names - MATLAB struct field names must start with a LETTER.
%
% The clones accept `struct('@anon3', ...)`, `struct('__st1_n', ...)` and
% `struct('.byte', ...)`; real MATLAB refuses each at construction time with
% 字段名称 ".byte" 无效 ("invalid field name"). Three separate defects in this project came
% from that difference, and the third was found only on the authority run - after 338 of 338
% corpus programs had been measured byte-identical on both clones. The clones cannot see the
% bug, so it is checked statically instead.
%
% Field names are the 1st, 3rd, 5th... arguments of a struct() call. This checks EVERY such
% position: the first version checked only the first, and reported
% struct('good', 1, '2bad', 2) as clean, which is worse than having no checker because it is
% believed.
%
% Returns a cell of "file:line: field name" strings; empty means clean.

txt = fileread(f);
bad = {};
needle = 'struct(';
at = strfind(txt, needle);
for q = 1:numel(at)
    i = at(q) + numel(needle);
    % a struct( mentioned in a COMMENT is documentation, not a field name. Full-line
    % comments only: a '%' inside a string literal means something else entirely, and
    % skipping those wrongly would hide real violations.
    ls = i;
    while ls > 1 && txt(ls-1) ~= char(10)
        ls = ls - 1;
    end
    lead = strtrim(txt(ls:i-1));
    if ~isempty(lead) && lead(1) == '%'
        continue;
    end
    args = call_arguments(txt, i);
    for k = 1:2:numel(args)
        nm = quoted_name(args{k});
        if isempty(nm)
            continue;                       % a variable or an expression: not a name here
        end
        c = nm(1);
        if ~((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
            line = numel(strfind(txt(1:i), char(10))) + 1;
            bad{end+1} = sprintf('%s:%d: field name %s', f, line, nm);
        end
    end
end
end

function args = call_arguments(txt, from)
% call_arguments - the top-level arguments of the call whose argument list starts at `from`,
% trimmed. Stops at the matching close paren.
args = {};
depth = 1;
start = from;
k = from;
while k <= numel(txt) && depth > 0
    c = txt(k);
    if c == '('
        depth = depth + 1;
    elseif c == ')'
        depth = depth - 1;
        if depth == 0
            args{end+1} = strtrim(txt(start:k-1));
            break;
        end
    elseif c == ',' && depth == 1
        args{end+1} = strtrim(txt(start:k-1));
        start = k + 1;
    end
    k = k + 1;
end
end

function nm = quoted_name(a)
% quoted_name - the content of `a` when it is a single quoted literal, else ''
nm = '';
if numel(a) < 2
    return;
end
q = a(1);
if q ~= '''' && q ~= '"'
    return;
end
if a(numel(a)) ~= q
    return;
end
inner = a(2:numel(a)-1);
if ~isempty(strfind(inner, q))            % not a single literal
    return;
end
nm = inner;
end
