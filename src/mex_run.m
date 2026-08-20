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
    error('mex_run: the gcc reference track is not implemented yet');
end

if strcmp(flag, 'compilecheck')
    % compile-only track: cc_int must accept the source (the `mex
    % -backend matlabcc` throwaway check); no harness, no simulation.
    [fp2, fb2] = fileparts(srcfile);
    tmpc2 = fullfile(fp2, ['tmp_mxrun_', fb2, '.c']);
    tmps2 = fullfile(fp2, ['tmp_mxrun_', fb2, '.s']);
    src2 = fileread(srcfile);
    src2 = strrep(src2, char(13), '');   % CRLF -> LF (cc_int expects \n)
    mdx2 = strfind(src2, '/* ---- harness');
    if ~isempty(mdx2)
        src2 = src2(1:mdx2(1)-1);
    end
    src2 = [mx_preamble(), char(10), src2, char(10), ...
'mxArray *__mex_prhs[4];' char(10) ...
        'mxArray *__mex_plhs[4];' char(10) ...
        'int __mex_nrhs;' char(10) ...
        'int main()' char(10) ...
        '{' char(10) ...
        '        mexFunction(2, __mex_plhs, __mex_nrhs, __mex_prhs);' char(10) ...
        '        return 0;' char(10) ...
        '}' char(10)];
    fid2 = fopen(tmpc2, 'w');
    if fid2 < 0
        error('mex_run: could not write(%s)', tmpc2);
    end
    fprintf(fid2, '%s', char(src2));
    fclose(fid2);
    cc_int(tmpc2, tmps2);
    return;
end

if ~exist(srcfile, 'file')
    error('mex_run: could not open(%s)', srcfile);
end

% ---- assemble preamble + source + harness main into one file ----
[fp, fb] = fileparts(srcfile);
tmpc = fullfile(fp, ['tmp_mxrun_', fb, '.c']);
tmps = fullfile(fp, ['tmp_mxrun_', fb, '.s']);

src0 = fileread(srcfile);
src0 = strrep(src0, char(13), '');   % CRLF -> LF (cc_int expects \n)
% the group-11 corpus files embed their own harness main (for the raw
% cc_int/x86sim smoke); strip it so mex_run can append its generic one
mdx = strfind(src0, '/* ---- harness');
if ~isempty(mdx)
    src0 = src0(1:mdx(1)-1);
end
src = [mx_preamble(), char(10), src0, char(10), ...
'mxArray *__mex_prhs[4];' char(10) ...
    'mxArray *__mex_plhs[4];' char(10) ...
    'int __mex_nrhs;' char(10) ...
    'int main()' char(10) ...
    '{' char(10) ...
    '    mexFunction(2, __mex_plhs, __mex_nrhs, __mex_prhs);' char(10) ...
    '    return 0;' char(10) ...
    '}' char(10)];
fid = fopen(tmpc, 'w');
if fid < 0
    error('mex_run: could not write(%s)', tmpc);
end
fprintf(fid, '%s', char(src));
fclose(fid);

% ---- compile + simulate ----
cc_int(tmpc, tmps);
[outs, ~] = x86sim(tmps, varargin);
% [outs, ~] assigns the two varargouts directly: singling out the first
% element of the wrapped {outs, exit} cell (res{1}) makes the clone
% flatten a nested cell, so avoid the wrapper here.
end
