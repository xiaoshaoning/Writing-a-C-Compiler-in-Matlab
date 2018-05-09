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
  
  result = regexp(current_line, 'return.+', 'match');
  if size(result) > 0
      return_value = result{1}(8:end-1);
      break;
  end
end
  
fclose(fid);

if ~isempty(return_value) 
    fid_output = fopen(destination_file, 'w+');
    fprintf(fid_output, '\t.file\t\"return_2.c\"\n');
    fprintf(fid_output, '\t.text\n');
    fprintf(fid_output, '\t.globl\tmain\n');
    fprintf(fid_output, '\t.type\tmain, @function\n');
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
    fprintf(fid_output, '\t.size\tmain, .-main\n');
    fclose(fid_output);
end    

end
