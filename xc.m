function exit_code = xc(varargin)
% xc — C interpreter (port of lotabout/write-a-C-interpreter/xc.c).
%
%   xc('hello.c')               interpret a C file
%   xc('-s', 'hello.c')         dump source + generated instructions
%   xc('-d', 'hello.c')         trace executed instructions
%
% Phase 0 scaffold: shared state, memory segments, argument handling and
% source loading are in place. The lexer/parser/VM pipeline is built in
% Phases 1-6 (see docs/2026-08-10-xc-matlab-port-plan.md).

% ---- shared interpreter state (mirrors xc.c globals) ----
global token token_val src si line          % lexer
global text ti pc bp sp ax cycle            % VM + text segment
global symbols symbol_names current_id idmain  % symbol table
global mem data_top hp stack_base           % memory segments
global poolsize assembly debug              % configuration

% ---- configuration defaults (xc.c: poolsize = 256 * 1024) ----
poolsize = 256 * 1024;
assembly = 0;
debug    = 0;

% ---- memory segments (0-based byte addressing, see plan) ----
mem          = zeros(1, 3*poolsize, 'uint8'); % [0,2P) data+heap, [2P,3P) stack
text         = zeros(1, 32768, 'int64');      % instruction segment (0-based word index)
ti           = 0;                             % next free text slot
symbols      = zeros(3276, 10, 'int64');      % symbol table, IdSize = 10
symbol_names = cell(3276, 1);                 % identifier strings
current_id   = 0;
idmain       = 0;
data_top     = 0;
hp           = 0;
stack_base   = 3 * poolsize;
sp           = stack_base;
bp           = stack_base;
pc           = 0;
ax           = int64(0);
cycle        = 0;

% ---- lexer state ----
line      = 1;
token     = 0;
token_val = 0;
src       = '';
si        = 0;

% ---- argument parsing: [-s] [-d] file ... ----
% v1.2.38 fixed zero-arg varargin ({} not {''}) and c(1) = [] (removes the
% element), so the natural MATLAB form works again.
args = varargin;
while ~isempty(args) && ischar(args{1}) && ~isempty(args{1}) && args{1}(1) == '-'
    switch args{1}
        case '-s', assembly = 1;
        case '-d', debug = 1;
        otherwise, fail(sprintf('unknown option %s', args{1}));
    end
    args(1) = [];
end
if isempty(args)
    fail('usage: xc [-s] [-d] file ...');
end
source_file = args{1};  % xc.c only reads the first file

% ---- load source (fread + char; must read bytes, not doubles) ----
% Plain fread(fid, inf) reads 8-byte double units — a 21-byte file yields 2
% elements. '*char' precision is also broken on the runtime, so read 'uint8'.
fid = fopen(source_file, 'r');
if fid < 0
    fail(sprintf('could not open(%s)', source_file));
end
src = char(fread(fid, inf, 'uint8')');
fclose(fid);
si = 0;

% ---- Phase 0: pipeline lands in Phases 1-6 ----
fail('interpreter pipeline not implemented yet (Phases 1-6)');

exit_code = 0;   % unreachable until eval() lands
end

% ---------------------------------------------------------------------------
% helpers
% ---------------------------------------------------------------------------

function fail(msg, ln)
% fail — error out with an optional source line (mirrors xc.c's
% printf("%d: ...", line); exit(-1) pattern).
if nargin >= 2 && ~isempty(ln)
    msg = sprintf('%d: %s', ln, msg);
end
error(msg);
end

function emit(op)
% emit — append one instruction word to the text segment.
global text ti
if ti + 1 > numel(text)
    fail('text segment overflow');
end
ti = ti + 1;
text(ti) = int64(op);
end

function v = word_load(a)
% word_load — int64 value at 0-based byte address a (8 bytes, little-endian).
global mem
if a < 0 || a + 8 > numel(mem)
    fail(sprintf('word_load: address %d out of range', a));
end
% v1.2.38 keeps the uint8 type on slices (BUG-7 fixed), so a direct
% typecast reinterprets the 8 bytes as one int64.
v = typecast(mem(a+1:a+8), 'int64');
end

function word_store(a, v)
% word_store — write int64 v to 0-based byte address a.
% Exact for |v| < 2^53 (int64 beyond that is not exactly representable);
% fails loudly instead of corrupting memory.
global mem
if a < 0 || a + 8 > numel(mem)
    fail(sprintf('word_store: address %d out of range', a));
end
v64 = int64(v);
if abs(double(v64)) >= 2^53
    fail(sprintf('word_store: value %d exceeds exact int64 range', double(v64)));
end
for k = 0:7
    b = mod(v64, int64(256));
    mem(a+k+1) = uint8(b);
    v64 = int64((v64 - b) / int64(256));
end
end

function a = align8(a)
% align8 — round a byte address up to an 8-byte boundary (xc.c's
% (addr + sizeof(int)) & -sizeof(int) on the data segment).
a = a + mod(-a, 8);
end

function n = opname(op)
% opname — instruction mnemonic for opcode (0-based), for -s/-d dumps.
names = {'LEA','IMM','JMP','CALL','JZ','JNZ','ENT','ADJ','LEV','LI','LC','SI','SC','PUSH', ...
         'OR','XOR','AND','EQ','NE','LT','GT','LE','GE','SHL','SHR','ADD','SUB','MUL','DIV','MOD', ...
         'OPEN','READ','CLOS','PRTF','MALC','MSET','MCMP','EXIT'};
if op >= 0 && op < numel(names)
    n = names{op+1};
else
    n = '????';
end
end
