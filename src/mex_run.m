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
        any(strcmp(varargin{end}, {'compile', 'gcc', 'interpret'}))
    flag = varargin{end};
    varargin(end) = [];
end

if strcmp(flag, 'gcc')
    error('mex_run: the gcc reference track is not implemented yet');
end

if ~exist(srcfile, 'file')
    error('mex_run: could not open(%s)', srcfile);
end

% ---- assemble preamble + source + harness main into one file ----
[fp, fb] = fileparts(srcfile);
tmpc = fullfile(fp, ['tmp_mxrun_', fb, '.c']);
tmps = fullfile(fp, ['tmp_mxrun_', fb, '.s']);

src0 = fileread(srcfile);
% the group-11 corpus files embed their own harness main (for the raw
% cc_int/x86sim smoke); strip it so mex_run can append its generic one
mdx = strfind(src0, '/* ---- harness');
if ~isempty(mdx)
    src0 = src0(1:mdx(1)-1);
end
src = [mx_preamble(), char(10), src0, char(10), mex_run_harness()];
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

function txt = mex_run_harness()
% mex_run_harness — the synthetic main that calls the corpus's
% mexFunction.  x86sim mex-mode writes __mex_prhs/__mex_nrhs before main
% and reads __mex_plhs[0..1] after.
txt = [ ...
    'mxArray *__mex_prhs[4];' char(10) ...
    'mxArray *__mex_plhs[4];' char(10) ...
    'int __mex_nrhs;' char(10) ...
    'int main()' char(10) ...
    '{' char(10) ...
    '    mexFunction(2, __mex_plhs, __mex_nrhs, __mex_prhs);' char(10) ...
    '    return 0;' char(10) ...
    '}' char(10) ...
    ];
end