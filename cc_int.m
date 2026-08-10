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
  
  % A literal search + manual slice is used instead of 'return.+' (which
  % relies on regexp quantifiers); both are equivalent for "return <const>;"
  % lines, and this form is portable across MATLAB implementations.
  result = regexp(current_line, 'return');
  if ~isempty(result)
      return_value = current_line(result(1)+7:end-1);
      break;
  end
end
  
fclose(fid);

if ~isempty(return_value) 
    fid_output = fopen(destination_file, 'w+');
    fprintf(fid_output, '\t.file\t\"return_2.c\"\n');
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
    fprintf(fid_output, '\tmovl\t$%d, ', str2num(return_value));
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
