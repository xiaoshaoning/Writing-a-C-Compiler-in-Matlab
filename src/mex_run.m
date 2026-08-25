function outs = mex_run(srcfile, varargin)
% MEX_RUN — run a MEX source through the matlabcc pipeline.
%
%   outs = mex_run('src.c', x1, x2, ...)          % compile track (default)
%   outs = mex_run('src.c', x1, x2, 'compile')    % explicit
%   outs = mex_run('src.c', x1, x2, 'gcc')        % reference track (TBD)
%
% The driver assembles the mx declaration preamble (mx_preamble) + the
% MEX source + a synthetic harness `main`, compiles the whole thing with
% cc_int (MATLAB-based C compiler, gcc-free), and simulates it with
% x86sim in mex mode.  x86sim builds prhs from the input values, runs
% mexFunction, and returns the plhs as MATLAB arrays.  OUTS is a cell
% array of the output arrays (one per produced plhs).
%
% This is the compiler-independent oracle: the same source, compiled and
% run entirely without an external C compiler.
%
% NOTE: the clone's interpreter lets a callee's local writes leak back
% into the caller's workspace when the names collide, so every local
% here carries the mr_ prefix to avoid clobbering the caller's script
% variables (that leak is the reason the previous plain names corrupted
% a caller variable named `src`).

if nargin < 1
    error('mex_run: usage mex_run(''src.c'', x1, x2, ...)');
end

flag = 'compile';
if ~isempty(varargin) && ischar(varargin{end}) && ...
        (strcmp(varargin{end}, 'compile') || strcmp(varargin{end}, 'gcc') || ...
         strcmp(varargin{end}, 'interpret') || strcmp(varargin{end}, 'compilecheck'))
    flag = varargin{end};
    varargin(end) = [];
end

if strcmp(flag, 'gcc')
    outs = mex_run_gcc(srcfile, varargin);
    return;
end

if strcmp(flag, 'compilecheck')
    % compile-only track: cc_int must accept the source (the `mex
    % -backend matlabcc` throwaway check); no harness, no simulation.
    [mr_fp2, mr_fb2] = fileparts(srcfile);
    mr_tmpc2 = fullfile(mr_fp2, ['tmp_mxrun_', mr_fb2, '.c']);
    mr_tmps2 = fullfile(mr_fp2, ['tmp_mxrun_', mr_fb2, '.s']);
    mr_src2 = fileread(srcfile);
    mr_src2 = strrep(mr_src2, char(13), '');   % CRLF -> LF (cc_int expects \n)
    mr_mdx2 = strfind(mr_src2, '/* ---- harness');
    if ~isempty(mr_mdx2)
        mr_src2 = mr_src2(1:mr_mdx2(1)-1);
    end
    mr_src2 = [mx_preamble(), char(10), mr_src2, char(10), ...
'mxArray *__mex_prhs[4];' char(10) ...
        'mxArray *__mex_plhs[4];' char(10) ...
        'int __mex_nrhs;' char(10) ...
        'int main()' char(10) ...
        '{' char(10) ...
        '    mexFunction(2, __mex_plhs, __mex_nrhs, __mex_prhs);' char(10) ...
        '    return 0;' char(10) ...
        '}' char(10)];
    mr_fid2 = fopen(mr_tmpc2, 'w');
    if mr_fid2 < 0
        error('mex_run: could not write(%s)', mr_tmpc2);
    end
    fprintf(mr_fid2, '%s', char(mr_src2));
    fclose(mr_fid2);
    cc_int(mr_tmpc2, mr_tmps2, 'nopeephole');
    return;
end

if ~exist(srcfile, 'file')
    error('mex_run: could not open(%s)', srcfile);
end

% ---- assemble preamble + source + harness main into one file ----
[mr_fp, mr_fb] = fileparts(srcfile);
mr_tmpc = fullfile(mr_fp, ['tmp_mxrun_', mr_fb, '.c']);
mr_tmps = fullfile(mr_fp, ['tmp_mxrun_', mr_fb, '.s']);

mr_src0 = fileread(srcfile);
mr_src0 = strrep(mr_src0, char(13), '');   % CRLF -> LF (cc_int expects \n)
% the group-11 corpus files embed their own harness main (for the raw
% cc_int/x86sim smoke); strip it so mex_run can append its generic one
mr_mdx = strfind(mr_src0, '/* ---- harness');
if ~isempty(mr_mdx)
    mr_src0 = mr_src0(1:mr_mdx(1)-1);
end
mr_src = [mx_preamble(), char(10), mr_src0, char(10), ...
'mxArray *__mex_prhs[4];' char(10) ...
    'mxArray *__mex_plhs[4];' char(10) ...
    'int __mex_nrhs;' char(10) ...
    'int main()' char(10) ...
    '{' char(10) ...
    '    mexFunction(2, __mex_plhs, __mex_nrhs, __mex_prhs);' char(10) ...
    '    return 0;' char(10) ...
    '}' char(10)];
mr_need_compile = 1;
if exist(mr_tmpc, 'file') && exist(mr_tmps, 'file')
    mr_old = strrep(fileread(mr_tmpc), char(13), '');   % written via fprintf (CRLF)
    if strcmp(mr_old, char(mr_src))
        mr_need_compile = 0;   % cache hit: same assembled source, reuse the .s
    end
end
if mr_need_compile
    mr_fid = fopen(mr_tmpc, 'w');
    if mr_fid < 0
        error('mex_run: could not write(%s)', mr_tmpc);
    end
    fprintf(mr_fid, '%s', char(mr_src));
    fclose(mr_fid);
    % ---- compile + simulate ----
    cc_int(mr_tmpc, mr_tmps, 'nopeephole');
end
[mr_outs, ~] = x86sim(mr_tmps, varargin);
% [mr_outs, ~] assigns the two varargouts directly: singling out the first
% element of the wrapped {outs, exit} cell (res{1}) makes the clone
% flatten a nested cell, so avoid the wrapper here.
outs = mr_outs;
end
