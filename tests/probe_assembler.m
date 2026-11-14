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

% .data bytes, exactly: this section is not padded, so prefix-wise would be wrong - and it
% is what M1's data directives (.byte/.short/.long/.quad/.string) are judged by. Symbol
% offsets are compared at M4, where relocations give them a reason to exist.
refdata = uint8([]);
if system('objcopy -O binary --only-section=.data tmp_asm.o tmp_asm_d.bin') == 0 && ...
        exist('tmp_asm_d.bin', 'file') == 2
    fid = fopen('tmp_asm_d.bin', 'r');
    refdata = fread(fid, inf, 'uint8').';
    fclose(fid);
end

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

% Both sections by the same rule, in one place: the reference is padded to a section
% boundary for .data as much as for .text (a 22-byte .data comes back as 32), so a
% whole-section equality test reports a length difference where the bytes are right.
% Nothing to guard here: a throw returned above.
compare_bytes('data', refdata, img.data);
compare_bytes('text', ref, ours);
finish(made_sample);
end

function finish(made_sample)
% every exit path: scratch files only the probe created, and only if it created them
delete_if_exists('tmp_asm_in.s');
delete_if_exists('tmp_asm.o');
delete_if_exists('tmp_asm.bin');
delete_if_exists('tmp_asm_d.bin');
if made_sample && exist('tmp_asm.s', 'file') == 2
    delete('tmp_asm.s');
end
end

% ---------------------------------------------------------------------------------

function compare_bytes(what, ref, ours)
% compare_bytes - our bytes against the reference's PREFIX, and say which it was.
%
% The reference section is padded to an alignment boundary (measured: five bytes of code
% came back as sixteen, and a 22-byte .data as 32), so the rule is prefix equality - plus
% a loud report when ours is empty and the reference is not, because a comparison of no
% bytes is not a match and printing MATCH there was this harness's own first bug.
if isempty(ours) && ~isempty(ref)
    fprintf('  %-5s VACUOUS ours is empty and the reference is not\n', what);
    return;
end
n = min(numel(ours), numel(ref));
diff = 0;
for k = 1:n
    if ours(k) ~= ref(k)
        diff = k;
        break;
    end
end
if diff > 0
    fprintf('  %-5s MISMATCH at byte %d\n', what, diff);
    fprintf('        ref  [%s]\n', hex_window(ref, diff));
    fprintf('        ours [%s]\n', hex_window(ours, diff));
elseif numel(ours) > numel(ref)
    fprintf('  %-5s LONGER than the reference by %d bytes\n', ...
            what, numel(ours) - numel(ref));
else
    fprintf('  %-5s MATCH  (%d bytes; the reference is padded)\n', what, n);
end
end

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
