% cc_int.m — x86-64 assembly compiler for `return <int>;` (Norasandler series,
% part 1).
% Copyright (C) 2026 Xiao, Shaoning <xiaoshaoning@foxmail.com>
%
% This program is free software; you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation; either version 2 of the License, or (at your option)
% any later version.
%
% This program is distributed in the hope that it will be useful, but
% WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
% or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
% for more details.

function cc_int(varargin)

if nargin ~= 2
   error('USAGE: cc_int return_2.c return_2.s');
end

source_file = varargin{1};

destination_file = varargin{2};

fid = fopen(source_file, 'r');

return_value = [];

while 1
  current_line = fgetl(fid);

  if ~ischar(current_line)
      break;
  end

  % Manual scan (no regexp quantifiers — portability note below): find the
  % literal 'return', then skip whitespace, an optional '-', and read the
  % digits. Tolerates spacing variants ("return 2;", "return2;",
  % "return -2;") and rejects identifiers/comments containing "return"
  % ("myreturn", "returnValue", "// returns ...") because the next char
  % is not whitespace or a digit.
  result = regexp(current_line, 'return');
  if ~isempty(result)
      k = result(1) + 6;          % first char after 'return'
      while k <= numel(current_line) && ...
            (current_line(k) == ' ' || current_line(k) == char(9))
          k = k + 1;
      end
      sign = 1;
      if k <= numel(current_line) && current_line(k) == '-'
          sign = -1;
          k = k + 1;
      end
      v = 0;
      got = 0;
      while k <= numel(current_line) && ...
            current_line(k) >= '0' && current_line(k) <= '9'
          v = v * 10 + (current_line(k) - '0');
          k = k + 1;
          got = 1;
      end
      if got
          % the rest of the line must be whitespace and an optional ';'
          % (a plain integer constant only — part-1 scope is `return <int>;`)
          while k <= numel(current_line) && ...
                (current_line(k) == ' ' || current_line(k) == char(9))
              k = k + 1;
          end
          if k <= numel(current_line) && current_line(k) == ';'
              k = k + 1;   % anything after ';' is ignored (comment/ws)
          elseif k <= numel(current_line)
              error(sprintf('cc_int: return must be a plain integer constant: %s', ...
                  current_line));
          end
          return_value = sign * v;
          break;
      end
  end
end

fclose(fid);

if ~isempty(return_value)
    [~, name, ext] = fileparts(source_file);
    srcname = [name, ext];
    fid_output = fopen(destination_file, 'w+');
    fprintf(fid_output, '\t.file\t"%s"\n', srcname);
    fprintf(fid_output, '\t.text\n');
    fprintf(fid_output, '\t.globl\tmain\n');
    % Windows/MSYS2 binutils: ELF-style ".type main, @function" (the
    % Norasandler tutorial) is rejected — '@' starts a comment in COFF GAS.
    % gcc emits ".def main; .scl 2; .type 32; .endef" on this target.
    fprintf(fid_output, '\t.def\tmain;\t.scl\t2;\t.type\t32;\t.endef\n');
    fprintf(fid_output, 'main:\n');
    fprintf(fid_output, '.LFB0:\n');
    fprintf(fid_output, '\t.cfi_startproc\n');
    fprintf(fid_output, '\tpushq\t');
    fprintf(fid_output, '%%rbp');
    fprintf(fid_output, '\n');
    fprintf(fid_output, '\t.cfi_def_cfa_offset 16\n');
    fprintf(fid_output, '\t.cfi_offset 6, -16\n');
    fprintf(fid_output, '\tmovq\t');
    fprintf(fid_output, '%%rsp, ');
    fprintf(fid_output, '%%rbp');
    fprintf(fid_output, '\n');
    fprintf(fid_output, '\t.cfi_def_cfa_register 6\n');
    fprintf(fid_output, '\tmovl\t$%d, ', return_value);
    fprintf(fid_output, '%s\n', '%eax');
    fprintf(fid_output, '\tpopq\t');
    fprintf(fid_output, '%%rbp');
    fprintf(fid_output, '\n');
    fprintf(fid_output, '\t.cfi_def_cfa 7, 8\n');
    fprintf(fid_output, '\tret\n');
    fprintf(fid_output, '\t.cfi_endproc\n');
    fprintf(fid_output, '.LFE0:\n');
    fclose(fid_output);
end

end
