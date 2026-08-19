addpath('D:\Projects\github\xiaoshaoning\Writing-a-C-Compiler-in-Matlab\src');
try
    cc_int('D:\Projects\github\xiaoshaoning\Writing-a-C-Compiler-in-Matlab\tests\programs\d2c.c', 'D:\tmp\d2c.s');
    fprintf('OK\n');
catch err
    fprintf('ERR: %s\n', err.message);
    st = err.stack(1);
    fprintf('LINE: %d NAME: %s\n', st.line, st.name);
    for k = 1:min(4, numel(err.stack))
        fprintf('  %s:%d  %s\n', err.stack(k).file, err.stack(k).line, err.stack(k).name);
    end
end