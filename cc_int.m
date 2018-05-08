function cc_int(varargin)

if nargin ~= 2
   error('USAGE: cc_int return_2.c return_2.asm');  
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
    fprintf(fid_output, '__main:\nmov $%d, ', str2num(return_value));
    fprintf(fid_output, '%s\n', '%eax');
    fprintf(fid_output, 'ret');
    fclose(fid_output);
end    

end