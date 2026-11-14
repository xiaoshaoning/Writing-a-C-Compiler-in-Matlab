function [same, differ, refused, total] = asm_gate(first, count, only)
% asm_gate - M5: assemble corpus programs and compare the bytes with the reference assembler.
%
%   asm_gate()          every corpus program
%   asm_gate(first)     from `first` to the end (1-based)
%   asm_gate(first, n)  n programs starting at `first`
%   asm_gate(first, n, only)  restrict to these program names (a cell of char)
%
% The corpus is read from run_tests.m's cctests table, so this checks exactly what the suite
% checks - one source of truth for "which programs are the corpus", rather than a second
% list that drifts.
%
% For each program: compile it with cc_int, let as and objcopy produce the reference .text,
% assemble the same .s with ma_asm, and compare. The comparison is prefix-wise because the
% reference pads its section to a boundary (5 bytes of code come back as 16).
%
% Prints one line per failure and a tally. Returns the counts so a caller can assert on
% them instead of parsing the printout. A program that cc_int or ma_asm REFUSES is counted
% separately from one that produces wrong bytes: a refusal is a missing feature, wrong bytes
% are a bug.

names = corpus_names();
if nargin >= 3 && ~isempty(only)
    keep = {};
    for q = 1:numel(names)
        if any(strcmp(names{q}, only))
            keep{end+1} = names{q};
        end
    end
    names = keep;
end
if nargin < 1 || isempty(first)
    first = 1;
end
if nargin < 2 || isempty(count)
    count = numel(names);
end
last = min(numel(names), first + count - 1);

same = 0;
differ = 0;
refused = 0;
for k = first:last
    nm = names{k};
    src = ['tests/programs/' nm];
    try
        cc_int(src, 'tmp_asm_gate.s');
    catch e
        fprintf('  COMPILE %-24s %s\n', nm, e.message);
        refused = refused + 1;
        continue;
    end
    system('as --64 tmp_asm_gate.s -o tmp_asm_gate.o');
    system('objcopy -O binary --only-section=.text tmp_asm_gate.o tmp_asm_gate.bin');
    fid = fopen('tmp_asm_gate.bin', 'r');
    if fid < 0
        fprintf('  NO-BIN  %-24s as or objcopy produced no .text\n', nm);
        refused = refused + 1;
        continue;
    end
    ref = fread(fid, inf, 'uint8');
    fclose(fid);
    try
        img = ma_asm(fileread('tmp_asm_gate.s'));
    catch e
        fprintf('  REFUSED %-24s %s\n', nm, e.message);
        refused = refused + 1;
        continue;
    end
    n = min(numel(img.text), numel(ref));
    if n > 0 && isequal(double(img.text(1:n)), double(ref(1:n).'))
        same = same + 1;
    else
        differ = differ + 1;
        d = 1;
        if n > 0
            dd = find(double(img.text(1:n)) ~= double(ref(1:n).'));
            if ~isempty(dd)
                d = dd(1);
            end
        end
        fprintf('  DIFF    %-24s first at byte %d (mine %d, reference %d bytes)\n', ...
                nm, d, numel(img.text), numel(ref));
    end
end
fprintf('asm gate %d..%d of %d: %d byte-identical, %d differ, %d refused\n', ...
        first, last, numel(names), same, differ, refused);
total = last - first + 1;   % the count actually checked, which is what a caller asserts on
end

function names = corpus_names()
% corpus_names - the .c files of run_tests.m's cctests table, in order
txt = fileread('tests/run_tests.m');
lines = regexp(txt, char(10), 'split');
inTable = 0;
names = {};
for k = 1:numel(lines)
    L = strtrim(lines{k});
    if ~inTable
        if numel(L) >= 10 && strcmp(L(1:10), 'cctests = ')
            inTable = 1;
        end
        continue;
    end
    if numel(L) >= 2 && L(1) == '}'
        break;
    end
    q = find(L == '''', 1);
    if isempty(q)
        continue;
    end
    q2 = find(L == '''', 2);
    if numel(q2) < 2
        continue;
    end
    nm = L(q(1)+1:q2(2)-1);
    if numel(nm) > 2 && strcmp(nm(numel(nm)-1:numel(nm)), '.c')
        names{end+1} = nm;
    end
end
end
