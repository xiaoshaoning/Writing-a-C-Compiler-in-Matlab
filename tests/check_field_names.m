function bad = check_field_names(f)
% check_field_names - MATLAB struct field names must start with a LETTER.
%
% The clones accept `struct('@anon3', ...)`, `struct('__st1_n', ...)` and
% `struct('.byte', ...)`; real MATLAB refuses each of them at construction time with
% 字段名称 ".byte" 无效 ("invalid field name"). Three separate defects in this project came
% from that difference, and the third was found only on the authority run - after 338 of 338
% corpus programs had been measured byte-identical on both clones. The clones cannot see the
% bug, so it is checked statically instead: every struct() whose first field name does not
% start with a letter is reported, with its line.
%
% Returns a cell of "file:line: field name" strings; empty means clean.

txt = fileread(f);
bad = {};
needle = 'struct(';
at = strfind(txt, needle);
for q = 1:numel(at)
    i = at(q) + numel(needle);
    % skip spaces to the first character of the first argument
    while i <= numel(txt) && (txt(i) == ' ' || txt(i) == char(9))
        i = i + 1;
    end
    if i > numel(txt)
        continue;
    end
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
    qc = txt(i);
    if qc ~= '''' && qc ~= '"'
        continue;                       % not a literal field name; nothing to check
    end
    j = i + 1;
    while j <= numel(txt) && txt(j) ~= qc
        j = j + 1;
    end
    if j > numel(txt)
        continue;
    end
    nm = txt(i+1:j-1);
    if isempty(nm)
        continue;
    end
    c = nm(1);
    ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    if ~ok
        line = numel(strfind(txt(1:i), char(10))) + 1;
        bad{end+1} = sprintf('%s:%d: field name %s', f, line, nm);
    end
end
end
