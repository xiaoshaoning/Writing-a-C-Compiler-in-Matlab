run('t_names.m');
for k = 1:numel(names)
    try
        cc_int(['tests/programs/' names{k}], ['t_s/' names{k}(1:end-2) '.s']);
    catch e
    end
end
disp('done');
