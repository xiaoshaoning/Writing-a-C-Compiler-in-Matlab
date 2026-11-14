function probe_assembler(file)
% probe_assembler - compare ma_asm's bytes against the reference assembler.
%
%   probe_assembler                 on a small built-in sample
%   probe_assembler('x.s')          on a file
%
% The reference path is `as` (the assembler gcc itself uses) plus objcopy to extract
% .text. Everything this assembler will claim is judged by that comparison, so it is
% built first: a harness that is wrong makes every later milestone report a lie.
%
% Four things were measured while writing it, each of which would have produced a false
% result on every program:
%
%  - the reference .text is PADDED. Five bytes of code come back as sixteen, because gas
%    aligns the section. The comparison is therefore PREFIX-wise: our bytes must equal
%    the first numel(ours) reference bytes, and both lengths are printed either way.
%  - objcopy must write to a FILE; /dev/stdout does not work here.
%  - every path passed to the tools is a BARE NAME in the working directory. The engine's
%    system() rejects an absolute path handed to `as` ("can't create ...: Invalid
%    argument") and does not accept cmd's `cd /d`. The suite already uses tmp_* files in
%    the working directory for the same reason.
%  - `as` refusing a program is not a test of this assembler, and is reported as such
%    rather than as a mismatch.
%
% Never throws: it reports, so a sweep over the corpus can keep going.

if nargin < 1
    file = '';
end

made_sample = 0;
if isempty(file)
    % a sample with one instruction: the reference has something to show, and our
    % assembler has something to be missing
    file = 'tmp_asm.s';
    made_sample = 1;
    t = char(9);
    fid = fopen(file, 'w');
    fprintf(fid, '%s\n', [t '.text']);
    fprintf(fid, '%s\n', [t '.globl' t 'f']);
    fprintf(fid, '%s\n', 'f:');
    fprintf(fid, '%s\n', [t 'leaq' t '1(%rdi), %rax']);
    fprintf(fid, '%s\n', [t 'ret']);
    fclose(fid);
end

[~, base] = fileparts(file);
txt = fileread(file);

% ---- the reference ------------------------------------------------------------
copyfile(file, 'tmp_asm_in.s');
if system('as --64 tmp_asm_in.s -o tmp_asm.o') ~= 0 || exist('tmp_asm.o', 'file') ~= 2
    fprintf('probe: the reference assembler REFUSED %s (as said so above)\n', file);
    fprintf('       a program as cannot assemble is not a test of this assembler\n');
    finish(made_sample);
    return;
end
if system('objcopy -O binary --only-section=.text tmp_asm.o tmp_asm.bin') ~= 0 || ...
        exist('tmp_asm.bin', 'file') ~= 2
    fprintf('probe: objcopy could not extract .text from %s\n', file);
    finish(made_sample);
    return;
end
fid = fopen('tmp_asm.bin', 'r');
ref = fread(fid, inf, 'uint8').';
fclose(fid);

% ---- ours ---------------------------------------------------------------------
try
    img = ma_asm(txt);
    ours = img.text;
    threw = '';
catch e
    ours = [];
    threw = e.message;
end

% ---- the comparison -----------------------------------------------------------
fprintf('probe %s: reference %d bytes of .text', base, numel(ref));
if ~isempty(threw)
    fprintf(', ours: %s\n', threw);
    finish(made_sample);
    return;
end
fprintf(', ours %d bytes\n', numel(ours));

n = min(numel(ours), numel(ref));
diff = 0;
for k = 1:n
    if ours(k) ~= ref(k)
        diff = k;
        break;
    end
end

if n == 0 && numel(ref) > 0
    % A comparison of no bytes is not a match. M0 printed MATCH here for an assembler that
    % had emitted nothing at all - the exact lie this harness exists to prevent.
    fprintf('  VACUOUS ours is empty and the reference is not: nothing was verified\n');
elseif diff == 0 && numel(ours) <= numel(ref)
    fprintf('  MATCH  (%d bytes compared; the reference is padded to a section boundary)\n', n);
elseif diff == 0
    fprintf('  LONGER than the reference by %d bytes - that is a real difference\n', ...
            numel(ours) - numel(ref));
else
    fprintf('  MISMATCH at byte %d\n', diff);
    fprintf('    ref  [%s]\n', hex_window(ref, diff));
    fprintf('    ours [%s]\n', hex_window(ours, diff));
end
finish(made_sample);
end

function finish(made_sample)
% every exit path: scratch files only the probe created, and only if it created them
delete_if_exists('tmp_asm_in.s');
delete_if_exists('tmp_asm.o');
delete_if_exists('tmp_asm.bin');
if made_sample && exist('tmp_asm.s', 'file') == 2
    delete('tmp_asm.s');
end
end

% ---------------------------------------------------------------------------------

function delete_if_exists(p)
if exist(p, 'file') == 2
    delete(p);
end
end

function s = hex_window(b, at)
% a few bytes either side of `at`, as hex, with the offending one marked
lo = max(1, at - 6);
hi = min(numel(b), at + 9);
if lo > hi
    s = '';
    return;
end
s = '';
for k = lo:hi
    if k == at
        s = [s '<' sprintf('%02X', b(k)) '> '];
    else
        s = [s sprintf('%02X', b(k)) ' '];
    end
end
s = strtrim(s);
end
