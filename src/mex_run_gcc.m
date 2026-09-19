function outs = mex_run_gcc(srcfile, ins)
% MEX_RUN_GCC — the gcc reference track of mex_run.
%
%   outs = mex_run_gcc('src.c', {x1, x2, ...})
%
% Assembles the SAME code text the matlabcc track compiles — the type
% declaration block, the standalone native mx/mex runtime (mx_ref.c),
% and the source with preprocessor lines stripped (cc_int-style) — plus
% a harness main that loads the inputs and dumps the plhs.  The whole
% thing is compiled with real gcc, run natively, and the dump is parsed
% back into MATLAB arrays.  The caller compares these against the
% x86sim track's outputs: the two tracks share one contract and must
% agree (see the mex_run gcc cross-track gate in PROJECT_STATUS.md).
%
% NOTE: every local carries the mr_ prefix (clone callee-workspace leak
% quirk; see mex_run.m).

mr_proj = fileparts(mfilename('fullpath'));
mr_fp = fileparts(srcfile);
mr_fb = mr_fb_of(srcfile);
mr_tmpc = fullfile(mr_fp, ['tmp_mxrun_', mr_fb, '_gcc.c']);
mr_exe = fullfile(mr_fp, ['tmp_mxrun_', mr_fb, '_gcc.exe']);
mr_dat = fullfile(mr_fp, ['tmp_mxrun_', mr_fb, '_gcc.in']);
mr_out = fullfile(mr_fp, ['tmp_mxrun_', mr_fb, '_gcc.out']);

% ---- assemble: decls + mx_ref runtime + source + harness main ----
mr_decl = [ ...
	'#include <stdint.h>' 10 '#include <stdio.h>' 10 ...
	'#include <stdlib.h>' 10 '#include <string.h>' 10 ...
	'#include <math.h>' 10 '#include <stdarg.h>' 10 ...
	'typedef struct mxArray_tag mxArray;' 10 ...
	'typedef size_t mwSize;' 10 'typedef size_t mwIndex;' 10 ...
	'typedef char mxChar;' 10 'typedef char mxLogical;' 10 ...
	'typedef unsigned int mxComplexity;' 10 ...
	'typedef enum { mxUNKNOWN_CLASS = 0, mxCELL_CLASS = 1,' 10 ...
	'       mxSTRUCT_CLASS = 2, mxLOGICAL_CLASS = 3, mxCHAR_CLASS = 4,' 10 ...
	'       mxFUNCTION_CLASS = 5, mxDOUBLE_CLASS = 6, mxSINGLE_CLASS = 7,' 10 ...
	'       mxINT8_CLASS = 8, mxUINT8_CLASS = 9, mxINT16_CLASS = 10,' 10 ...
	'       mxUINT16_CLASS = 11, mxINT32_CLASS = 12, mxUINT32_CLASS = 13,' 10 ...
	'       mxINT64_CLASS = 14, mxUINT64_CLASS = 15, mxOBJECT_CLASS = 17 } mxClassID;' 10 ...
	'enum { mxREAL = 0, mxCOMPLEX = 1 };' 10 ];
mr_runtime = fileread(fullfile(mr_proj, 'mx_ref.c'));
mr_src0 = fileread(srcfile);
mr_src0 = strrep(mr_src0, char(13), '');
mr_mdx = strfind(mr_src0, '/* ---- harness');
if ~isempty(mr_mdx)
	mr_src0 = mr_src0(1:mr_mdx(1) - 1);
end
mr_src = mr_strip_preprocessor(mr_src0);
mr_harness = [ ...
	'static mxArray *__mex_prhs[4];' 10 ...
	'static mxArray *__mex_plhs[4];' 10 ...
	'extern void mexFunction(int nlhs, mxArray *plhs[], int nrhs,' 10 ...
	'                         const mxArray *prhs[]);' 10 ...
	'int main(int argc, char **argv)' 10 '{' 10 ...
	'    if (argc > 1 && !freopen(argv[1], "r", stdin)) return 2;' 10 ...
	'    if (argc > 2 && !freopen(argv[2], "w", stdout)) return 2;' 10 ...
	'    int __nrhs = __mx_load_inputs(__mex_prhs, 4);' 10 ...
	'    if (__nrhs < 0) return 2;' 10 ...
	'    mexFunction(2, __mex_plhs, __nrhs, (const mxArray **) __mex_prhs);' 10 ...
	'    __mx_dump_outputs(__mex_plhs, 4);' 10 ...
	'    return 0;' 10 '}' 10 ];
mr_asm = char([mr_decl, char(10), mr_runtime, char(10), mr_src, char(10), mr_harness]);

% ---- cache: rebuild the exe only if the assembly changed ----
mr_need = 1;
if exist(mr_tmpc, 'file') && exist(mr_exe, 'file')
	mr_old = strrep(fileread(mr_tmpc), char(13), '');
	if strcmp(mr_old, mr_asm)
		mr_need = 0;
	end
end
if mr_need
	mr_fid = fopen(mr_tmpc, 'w');
	if mr_fid < 0
		error('mex_run(gcc): could not write(%s)', mr_tmpc);
	end
	fprintf(mr_fid, '%s', mr_asm);
	fclose(mr_fid);
	mr_gcc = mr_find_gcc();
	mr_cmd = [mr_gcc, ' -O2 -w -std=c11 -o "', mr_win(mr_exe), '" "', ...
	          mr_win(mr_tmpc), '"'];
	[~, mr_rc] = system(mr_cmd);
	if mr_rc ~= 0 || ~exist(mr_exe, 'file')
		error('mex_run(gcc): gcc build failed for %s', srcfile);
	end
end

% ---- feed the inputs, run, parse the output dump ----
mr_serialize_inputs(ins, mr_dat);

mr_cmd2 = [mr_win(mr_exe), ' ', mr_win(mr_dat), ' ', mr_win(mr_out)];
[~, mr_rc2] = system(mr_cmd2);
if mr_rc2 ~= 0 || ~exist(mr_out, 'file')
	error('mex_run(gcc): run failed (rc=%g) for %s', mr_rc2, srcfile);
end
mr_txt = fileread(mr_out);
outs = mr_parse_outputs(mr_txt);
end

function mr_n = mr_fb_of(mr_srcfile)
	mr_sl = max([strfind(mr_srcfile, '/'), strfind(mr_srcfile, '\')]);
	if isempty(mr_sl)
		mr_sl = 0;
	end
	mr_rest = mr_srcfile(mr_sl + 1:end);
	mr_dot = strfind(mr_rest, '.');
	if isempty(mr_dot)
		mr_n = mr_rest;
	else
		mr_n = mr_rest(1:mr_dot(1) - 1);
	end
end

function mr_p = mr_win(mr_p)
	mr_p = strrep(mr_p, '/', '\');
end

function mr_g = mr_find_gcc()
	mr_loc = getenv('MW_MINGW64_LOC');
	if ~isempty(mr_loc)
		mr_g = [mr_loc, '/bin/gcc.exe'];
		if exist(mr_g, 'file')
			return;
		end
	end
	mr_try = 'C:/msys64/ucrt64/bin/gcc.exe';
	if exist(mr_try, 'file')
		mr_g = mr_try;
		return;
	end
	mr_g = 'gcc';
end

function mr_s = mr_strip_preprocessor(mr_src)
	mr_lines = cell(1, 0);
	mr_pos = 1;
	mr_n = numel(mr_src);
	while mr_pos <= mr_n
		mr_nl = strfind(mr_src(mr_pos:end), char(10));
		if isempty(mr_nl)
			mr_lines{end + 1} = mr_src(mr_pos:end);
			break;
		end
		mr_lines{end + 1} = mr_src(mr_pos:mr_pos + mr_nl(1) - 2);
		mr_pos = mr_pos + mr_nl(1);
	end
	mr_out = cell(1, numel(mr_lines));
	mr_k = 0;
	for mr_i = 1:numel(mr_lines)
		mr_ln = mr_lines{mr_i};
		mr_j = 1;
		while mr_j <= numel(mr_ln) && (mr_ln(mr_j) == ' ' || mr_ln(mr_j) == 9)
			mr_j = mr_j + 1;
		end
		if mr_j <= numel(mr_ln) && mr_ln(mr_j) == '#'
			continue;
		end
		mr_k = mr_k + 1;
		mr_out{mr_k} = mr_ln;
	end
	mr_s = '';
	for mr_i = 1:mr_k
		mr_s = [mr_s, mr_out{mr_i}, char(10)];
	end
end

% ---- input serialization (one spec per input, "N <n>" header first) ----
function mr_serialize_inputs(mr_ins, mr_dat)
	mr_fid = fopen(mr_dat, 'w');
	if mr_fid < 0
		error('mex_run(gcc): could not write(%s)', mr_dat);
	end
	fprintf(mr_fid, 'N %d\n', numel(mr_ins));
	for mr_i = 1:numel(mr_ins)
		mr_spec = mr_ser_spec(mr_ins{mr_i});
		fprintf(mr_fid, '%s\n', mr_spec);
	end
	fclose(mr_fid);
end

function mr_s = mr_ser_spec(mr_v)	if ischar(mr_v)
		mr_s = sprintf('C %d %s', numel(mr_v), mr_v);
	elseif issparse(mr_v)
		[mi, mj, mv] = find(mr_v);
		[mm, mn] = size(mr_v);
		mr_jc = zeros(1, mn + 1);
		for c = 1:mn
			mr_jc(c + 1) = mr_jc(c) + sum(mj == c);
		end
		mr_s = sprintf('SP %d %d %d ', mm, mn, numel(mv));
		for k = 1:numel(mv)
			mr_s = [mr_s, sprintf('%d ', mi(k) - 1)];
		end
		for k = 1:numel(mr_jc)
			mr_s = [mr_s, sprintf('%d ', mr_jc(k))];
		end
		for k = 1:numel(mv)
			mr_s = [mr_s, sprintf('%.17g ', mv(k))];
		end
	elseif iscell(mr_v)
		mr_s = sprintf('CE %d ', numel(mr_v));
		for k = 1:numel(mr_v)
			mr_s = [mr_s, mr_ser_spec(mr_v{k})];
		end
	elseif isstruct(mr_v)
		mr_fn = fieldnames(mr_v);
		mr_s = sprintf('ST %d ', numel(mr_fn));
		for k = 1:numel(mr_fn)
			mr_s = [mr_s, mr_fn{k}, ' '];
		end
		for k = 1:numel(mr_fn)
			mr_s = [mr_s, mr_ser_spec(mr_v(1).(mr_fn{k}))];
		end
	elseif islogical(mr_v)
		mr_s = sprintf('L %d %d %d ', 2, size(mr_v, 1), size(mr_v, 2));
		mr_vv = mr_v(:).';
		for k = 1:numel(mr_vv)
			mr_s = [mr_s, sprintf('%d ', double(mr_vv(k)))];
		end
	elseif isnumeric(mr_v) && strcmp(class(mr_v), 'int32')
		mr_s = sprintf('I %d %d %d ', 2, size(mr_v, 1), size(mr_v, 2));
		mr_vv = double(mr_v(:).');
		for k = 1:numel(mr_vv)
			mr_s = [mr_s, sprintf('%d ', mr_vv(k))];
		end
	elseif isnumeric(mr_v)
		[mm, mn] = size(mr_v);
		if isreal(mr_v)
			mr_s = sprintf('D %d %d %d ', 2, mm, mn);
			mr_vv = mr_v(:).';
			for k = 1:numel(mr_vv)
				mr_s = [mr_s, sprintf('%.17g ', mr_vv(k))];
			end
		else
			mr_vv = mr_v(:).';
			mr_s = sprintf('Z %d %d %d ', 2, mm, mn);
			for k = 1:numel(mr_vv)
				mr_s = [mr_s, sprintf('%.17g ', real(mr_vv(k)))];
			end
			for k = 1:numel(mr_vv)
				mr_s = [mr_s, sprintf('%.17g ', imag(mr_vv(k)))];
			end
		end
	else
		error('mex_run(gcc): unsupported input class %s', class(mr_v));
	end
end

% ---- output dump parsing (one spec per line) ----
function mr_outs = mr_parse_outputs(mr_txt)
	mr_outs = cell(1, 0);
	mr_pos = 1;
	mr_n = numel(mr_txt);
	while mr_pos <= mr_n
		mr_nl = strfind(mr_txt(mr_pos:end), char(10));
		if isempty(mr_nl)
			mr_line = mr_txt(mr_pos:end);
			mr_pos = mr_n + 1;
		else
			mr_line = mr_txt(mr_pos:mr_pos + mr_nl(1) - 2);
			mr_pos = mr_pos + mr_nl(1);
		end
		if ~isempty(mr_line)
			mr_outs{end + 1} = mr_parse_one(mr_line, 1);
		end
	end
end

function [mr_v, mr_i] = mr_parse_one(mr_s, mr_i)
	mr_n = numel(mr_s);
	while mr_i <= mr_n && (mr_s(mr_i) == ' ' || mr_s(mr_i) == 9)
		mr_i = mr_i + 1;
	end
	mr_t0 = mr_i;
	while mr_i <= mr_n && mr_s(mr_i) ~= ' ' && mr_s(mr_i) ~= 9
		mr_i = mr_i + 1;
	end
	mr_tok = mr_s(mr_t0:mr_i - 1);
	if strcmp(mr_tok, 'D')
		[mr_v, mr_i] = mr_parse_dbl(mr_s, mr_i, 0);
	elseif strcmp(mr_tok, 'Z')
		[mr_v, mr_i] = mr_parse_dbl(mr_s, mr_i, 1);
	elseif strcmp(mr_tok, 'C')
		[mr_len, mr_i] = mr_parse_int(mr_s, mr_i);
		while mr_i <= mr_n && (mr_s(mr_i) == ' ' || mr_s(mr_i) == 9)
			mr_i = mr_i + 1;
		end
		mr_v = mr_s(mr_i:mr_i + mr_len - 1);
		mr_i = mr_i + mr_len;
	elseif strcmp(mr_tok, 'I')
		[mr_v, mr_i] = mr_parse_intmat(mr_s, mr_i);
	elseif strcmp(mr_tok, 'L')
		[mr_v, mr_i] = mr_parse_logical(mr_s, mr_i);
	elseif strcmp(mr_tok, 'CE')
		[mr_ne, mr_i] = mr_parse_int(mr_s, mr_i);
		mr_v = cell(1, mr_ne);
		for mr_k = 1:mr_ne
			% a scalar temp, not [mr_v{mr_k}, mr_i] = ...: the clone
			% reshapes mr_v to NxN when a multi-output assignment targets
			% a cell element (see the mex_run gcc cell/sparse gate)
			[mr_ev, mr_i] = mr_parse_one(mr_s, mr_i);
			mr_v{mr_k} = mr_ev;
		end
	elseif strcmp(mr_tok, 'ST')
		[mr_nf, mr_i] = mr_parse_int(mr_s, mr_i);
		mr_fn = cell(1, mr_nf);
		for mr_k = 1:mr_nf
			while mr_i <= mr_n && (mr_s(mr_i) == ' ' || mr_s(mr_i) == 9)
				mr_i = mr_i + 1;
			end
			mr_t0 = mr_i;
			while mr_i <= mr_n && mr_s(mr_i) ~= ' ' && mr_s(mr_i) ~= 9
				mr_i = mr_i + 1;
			end
			mr_fn{mr_k} = mr_s(mr_t0:mr_i - 1);
		end
		mr_v = struct();
		for mr_k = 1:mr_nf
			[mr_fv, mr_i] = mr_parse_one(mr_s, mr_i);
			mr_v.(mr_fn{mr_k}) = mr_fv;
		end
	elseif strcmp(mr_tok, 'SP')
		[mr_v, mr_i] = mr_parse_sparse(mr_s, mr_i);
	else
		error('mex_run(gcc): bad dump token "%s"', mr_tok);
	end
end

function [mr_v, mr_i] = mr_parse_dbl(mr_s, mr_i, mr_cx)
	mr_n = numel(mr_s);
	[mr_rank, mr_i] = mr_parse_int(mr_s, mr_i);
	mr_d = ones(1, max(mr_rank, 1));
	for mr_k = 1:mr_rank
		[mr_d(mr_k), mr_i] = mr_parse_int(mr_s, mr_i);
	end
	mr_nel = prod(mr_d);
	mr_re = zeros(1, mr_nel);
	for mr_k = 1:mr_nel
		[mr_tok, mr_i] = mr_parse_tok(mr_s, mr_i);
		mr_re(mr_k) = str2double(mr_tok);
	end
	if mr_cx
		mr_im = zeros(1, mr_nel);
		for mr_k = 1:mr_nel
			[mr_tok, mr_i] = mr_parse_tok(mr_s, mr_i);
			mr_im(mr_k) = str2double(mr_tok);
		end
		mr_v = reshape(mr_re, mr_d) + 1i * reshape(mr_im, mr_d);
	else
		mr_v = reshape(mr_re, mr_d);
	end
end

function [mr_v, mr_i] = mr_parse_intmat(mr_s, mr_i)
	mr_n = numel(mr_s);
	[mr_rank, mr_i] = mr_parse_int(mr_s, mr_i);
	mr_d = ones(1, max(mr_rank, 1));
	for mr_k = 1:mr_rank
		[mr_d(mr_k), mr_i] = mr_parse_int(mr_s, mr_i);
	end
	mr_nel = prod(mr_d);
	mr_vv = zeros(1, mr_nel, 'int32');
	for mr_k = 1:mr_nel
		[mr_tok, mr_i] = mr_parse_tok(mr_s, mr_i);
		mr_vv(mr_k) = int32(str2double(mr_tok));
	end
	mr_v = reshape(mr_vv, mr_d);
end

function [mr_v, mr_i] = mr_parse_logical(mr_s, mr_i)
	mr_n = numel(mr_s);
	[mr_rank, mr_i] = mr_parse_int(mr_s, mr_i);
	mr_d = ones(1, max(mr_rank, 1));
	for mr_k = 1:mr_rank
		[mr_d(mr_k), mr_i] = mr_parse_int(mr_s, mr_i);
	end
	mr_nel = prod(mr_d);
	mr_vv = zeros(1, mr_nel);
	for mr_k = 1:mr_nel
		[mr_tok, mr_i] = mr_parse_tok(mr_s, mr_i);
		mr_vv(mr_k) = str2double(mr_tok) ~= 0;
	end
	mr_v = logical(reshape(mr_vv, mr_d));
end

function [mr_v, mr_i] = mr_parse_sparse(mr_s, mr_i)
	[mr_m, mr_i] = mr_parse_int(mr_s, mr_i);
	[mr_n, mr_i] = mr_parse_int(mr_s, mr_i);
	[mr_nz, mr_i] = mr_parse_int(mr_s, mr_i);
	mr_ir = zeros(1, mr_nz);
	for mr_k = 1:mr_nz
		[mr_tok, mr_i] = mr_parse_tok(mr_s, mr_i);
		mr_ir(mr_k) = str2double(mr_tok);
	end
	mr_jc = zeros(1, mr_n + 1);
	for mr_k = 1:mr_n + 1
		[mr_tok, mr_i] = mr_parse_tok(mr_s, mr_i);
		mr_jc(mr_k) = str2double(mr_tok);
	end
	mr_pr = zeros(1, mr_nz);
	for mr_k = 1:mr_nz
		[mr_tok, mr_i] = mr_parse_tok(mr_s, mr_i);
		mr_pr(mr_k) = str2double(mr_tok);
	end
	mi = zeros(1, 0);
	mj = zeros(1, 0);
	mv = zeros(1, 0);
	for mr_k = 1:mr_nz
		mr_c = 1;
		% jc is 0-based cumulative (jc[c+1] <= k, k 0-based); mr_k is
		% 1-based, hence the -1 (see mx_ref.c's own reader)
		while mr_c <= mr_n && mr_jc(mr_c + 1) <= mr_k - 1
			mr_c = mr_c + 1;
		end
		mi(end + 1) = mr_ir(mr_k) + 1;
		mj(end + 1) = mr_c;
		mv(end + 1) = mr_pr(mr_k);
	end
	mr_v = sparse(mi, mj, mv, mr_m, mr_n);
end

function [mr_tok, mr_i] = mr_parse_tok(mr_s, mr_i)
	mr_n = numel(mr_s);
	while mr_i <= mr_n && (mr_s(mr_i) == ' ' || mr_s(mr_i) == 9)
		mr_i = mr_i + 1;
	end
	mr_t0 = mr_i;
	while mr_i <= mr_n && mr_s(mr_i) ~= ' ' && mr_s(mr_i) ~= 9
		mr_i = mr_i + 1;
	end
	mr_tok = mr_s(mr_t0:mr_i - 1);
end

function [mr_v, mr_i] = mr_parse_int(mr_s, mr_i)
	[mr_tok, mr_i] = mr_parse_tok(mr_s, mr_i);
	mr_v = str2double(mr_tok);
end
