% xc.m — C interpreter (port of lotabout/write-a-C-interpreter/xc.c, itself
% derived from c4).
% Copyright (C) 2026 Xiao, Shaoning <xiaoshaoning@foxmail.com>
%
% This program is free software; you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation; either version 2 of the License, or (at your option)
% any later version.
%
% This program is distributed in the hope that it will be useful, but
% WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
% or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
% for more details.
%
% You should have received a copy of the GNU General Public License along
% with this program; if not, write to the Free Software Foundation, Inc.,
% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
% Original source: https://github.com/lotabout/write-a-C-interpreter (xc.c,
% GPL2); tests/programs/hello.c is copied from the same repository.

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
global old_src old_text                     % -s dump state
global text ti pc bp sp ax cycle            % VM + text segment
global symbols symbol_names current_id idmain array_strides  % symbol table
global ginit ginit_n                                % global runtime inits
global mem data hp stack_base      % memory segments
global expr_type basetype index_of_bp unit_was_array bstrides  % parser state
global fidv                                 % syscall fd registry
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
array_strides = cell(3276, 1);   % per-level byte strides for array symbols
ginit        = cell(1, 64);      % {addr, src pos, is_char} — global runtime inits
ginit_n      = 0;
current_id   = 0;
idmain       = 0;
data         = 0;                           % next free data byte (xc.c char *data)
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
old_src   = 0;      % 0-based index of the current source line start
old_text  = 0;      % 0-based slot of the last -s-dumped instruction

% ---- parser state ----
expr_type    = 1;   % INT
basetype     = 1;
index_of_bp  = 0;
unit_was_array = 0;
bstrides     = [];   % per-level byte strides of the current array-typed expr
fidv         = [];  % OPEN/READ/CLOS registry (double vector)

% ---- hidden self-test entries (Phases 1-2): must be checked before the
% option parser ('--...' starts with '-'). Return nonzero on any failed case. ----
if nargin >= 1 && ischar(varargin{1})
    switch varargin{1}
        case '--vm-selftest'
            exit_code = vm_selftest();
            return;
        case '--lex-selftest'
            exit_code = lex_selftest();
            return;
    end
end

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

% ---- seed keywords + syscalls into the symbol table (xc.c main) ----
% Must run BEFORE loading the source file: seed_symbols() lexes the keyword
% string through src/si, which the file load then overwrites.
seed_symbols();

% ---- load source (fread + char; must read bytes, not doubles) ----
% Plain fread(fid, inf) reads 8-byte double units — a 21-byte file yields 2
% elements. '*char' precision is also broken on the runtime, so read 'uint8'.
fid = fopen(source_file, 'r');
if fid < 0
    fail(sprintf('could not open(%s)', source_file));
end
src = char(fread(fid, inf, 'uint8')');
fclose(fid);
src = [src, char(0), char(0)];   % NUL-terminate (two NULs: the string-literal
                                 % branch over-reads one past an unterminated literal)
si = 0;

% ---- compile (Phases 3-6) ----
program();

if assembly
    % -s: source + instruction dump only, no execution
    exit_code = 0;
    return;
end

if idmain == 0 || symbols(idmain, 6) == 0
    fail('main() not defined');
end

hp = data;   % MALC bump pointer starts after the compiled data

% ---- main-return sentinel (adapts xc.c's stack trick to the two-space
% model): main's LEV restores pc from frame slot 1; point it at an
% appended PUSH/EXIT pair in the text segment so the return value is
% pushed and handed to EXIT. ----
emit(13);                   % PUSH opcode
T_sentinel = ti + 1;        % 1-based pc of the PUSH slot
emit(37);                   % EXIT opcode

% ---- stack setup (xc.c main): frame slots bp[1] = return pc,
% bp[2] = argv, bp[3] = argc; entry sp = sp0, frame grows below. ----
sp0 = stack_base - 32;
word_store(sp0, T_sentinel);
word_store(sp0+8, 0);       % argv (no argv strings in the port)
word_store(sp0+16, 1);      % argc
sp = sp0;
bp = sp0;

if ginit_n > 0
    % startup prologue: run the recorded global runtime initializers, then
    % jump to main. (Re-parsed here from the recorded source positions, so
    % the emitted code lands after the sentinel, before main runs.)
    ginit_start = ti + 2;   % 1-based pc of the first prologue instruction
                            % (slot ti+1 sits at text(ti+2))
    for k = 1:ginit_n
        g = ginit{k};
        si = g{2};
        next();
        emit(1);                 % IMM
        emit(g{1});              % global byte address
        emit(13);                % PUSH
        expression(142);         % expression(Assign)
        emit(pick(g{3} ~= 0, 12, 11));   % SC for char, SI otherwise
    end
    emit(2);                     % JMP
    emit(symbols(idmain,6));     % 0-based main slot (pc = target + 1)
    pc = ginit_start;
else
    pc = symbols(idmain, 6) + 1;   % Fun Value is a 0-based slot; pc is 1-based
end
exit_code = vm_eval();
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
% Slot s (0-based) lives at text(s+1); slot 0 is unused, so the first
% emitted instruction is at slot 1 -> text(2). pc values elsewhere are
% 1-based (vm_eval fetches text(pc)), so a slot's 1-based index is s+1.
global text ti
if ti + 1 > numel(text)
    fail('text segment overflow');
end
ti = ti + 1;
text(ti+1) = int64(op);
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

% ---------------------------------------------------------------------------
% Phase 1: the VM (port of xc.c eval())
% ---------------------------------------------------------------------------

function exit_code = vm_eval()
% vm_eval — run the 38-opcode stack VM (port of xc.c eval() with the plan's
% byte-scaling table). Returns the value pushed by EXIT.
%
% Register/memory conventions:
%   pc   = 1-based text index; the next op is text(pc); fetch advances pc
%   op   = opcode (0-based, xc.c enum order — see opname)
%   jump/call operands are 0-based slot targets: a taken jump sets
%          pc = operand + 1  (slot `target` <-> text(target+1))
%   sp/bp = byte addresses; the stack grows down; every word is 8 bytes
%   ax   = int64 accumulator
global text pc bp sp ax cycle mem debug

cycle = 0;
while true
    cycle = cycle + 1;
    op = text(pc); pc = pc + 1;

    % execution trace (-d): mirror xc.c's "%d> %.4s" + operand for ops <= ADJ
    if debug
        fprintf('%d> %s', cycle, opname(op));
        if op <= 7   % ADJ: ops with a following operand slot
            fprintf(' %d\n', text(pc));
        else
            fprintf('\n');
        end
    end

    if op == 1            % IMM
        ax = text(pc); pc = pc + 1;
    elseif op == 10       % LC
        ax = double(mem(ax+1));
    elseif op == 9        % LI
        ax = word_load(ax);
    elseif op == 12       % SC  (address popped from stack, low byte stored)
        a = word_load(sp); sp = sp + 8;
        mem(a+1) = uint8(mod(ax, int64(256)));
    elseif op == 11       % SI  (address popped from stack)
        a = word_load(sp); sp = sp + 8;
        word_store(a, ax);
    elseif op == 13       % PUSH
        sp = sp - 8; word_store(sp, ax);
    elseif op == 2        % JMP
        pc = text(pc) + 1;
    elseif op == 4        % JZ
        if ax ~= 0
            pc = pc + 1;          % not taken: skip the operand slot
        else
            pc = text(pc) + 1;    % taken: jump to the operand target
        end
    elseif op == 5        % JNZ
        if ax ~= 0
            pc = text(pc) + 1;
        else
            pc = pc + 1;
        end
    elseif op == 3        % CALL: push return address (1-based), jump
        sp = sp - 8; word_store(sp, pc + 1);
        pc = text(pc) + 1;
    elseif op == 6        % ENT n: frame with n local slots
        n = text(pc); pc = pc + 1;
        sp = sp - 8; word_store(sp, bp); bp = sp;
        sp = sp - 8*n;
    elseif op == 7        % ADJ n: pop n argument slots
        sp = sp + 8*text(pc); pc = pc + 1;
    elseif op == 8        % LEV: restore frame and return address
        sp = bp;
        bp = word_load(sp); sp = sp + 8;
        pc = word_load(sp); sp = sp + 8;
    elseif op == 0        % LEA off
        ax = bp + 8*text(pc); pc = pc + 1;
    elseif op >= 14 && op <= 29   % binary ops: pop lhs, compute with ax
        lhs = word_load(sp); sp = sp + 8;
        if op == 14            % OR
            ax = bitor(lhs, ax);
        elseif op == 15        % XOR
            ax = bitxor(lhs, ax);
        elseif op == 16        % AND
            ax = bitand(lhs, ax);
        elseif op == 17        % EQ
            ax = int64(lhs == ax);
        elseif op == 18        % NE
            ax = int64(lhs ~= ax);
        elseif op == 19        % LT
            ax = int64(lhs < ax);
        elseif op == 20        % GT
            ax = int64(lhs > ax);
        elseif op == 21        % LE
            ax = int64(lhs <= ax);
        elseif op == 22        % GE
            ax = int64(lhs >= ax);
        elseif op == 23        % SHL
            ax = bitshift(lhs, double(ax));
        elseif op == 24        % SHR (arithmetic on int64; BUG-11 fixed in
            ax = bitshift(lhs, -double(ax));   % v1.2.39)
        elseif op == 25        % ADD
            ax = lhs + ax;
        elseif op == 26        % SUB
            ax = lhs - ax;
        elseif op == 27        % MUL
            ax = lhs * ax;
        elseif op == 28        % DIV (C truncating division)
            [ax, ~] = cdivmod(lhs, ax);
        elseif op == 29        % MOD (C remainder, sign of dividend)
            [~, ax] = cdivmod(lhs, ax);
        end
    elseif op == 37       % EXIT
        fprintf('exit(%d)', double(word_load(sp)));
        exit_code = word_load(sp);
        return;
    elseif op >= 30 && op <= 36   % syscalls (OPEN..MCMP); EXIT handled above
        % The ADJ <n> the parser emits after the opcode doubles as the arg
        % count (xc.c:1271): pc points at the ADJ; its operand is text(pc+1).
        % Args were pushed in source order, so sp is at the last arg and
        % tmp = sp + 8*n is one word past; tmp[-k] = the k-th pushed arg.
        nargs = text(pc + 1);
        tmp = sp + 8*nargs;
        if op == 30        % OPEN: open(path, flags)
            ax = sys_open(word_load(sp + 8), word_load(sp));
        elseif op == 31    % READ: read(fd, buf, count)
            ax = sys_read(word_load(sp + 16), word_load(sp + 8), word_load(sp));
        elseif op == 32    % CLOS
            ax = sys_close(word_load(sp));
        elseif op == 33    % PRTF
            ax = sys_prtf(tmp, nargs);
        elseif op == 34    % MALC
            ax = sys_malc(word_load(sp));
        elseif op == 35    % MSET: memset(dest, val, count)
            ax = sys_mset(word_load(sp + 16), word_load(sp + 8), word_load(sp));
        elseif op == 36    % MCMP: memcmp(s1, s2, count)
            ax = sys_mcmp(word_load(sp + 16), word_load(sp + 8), word_load(sp));
        end
    else
        fail(sprintf('unknown instruction:%d', op));
    end
end
end

function [q, r] = cdivmod(a, b)
% cdivmod — C truncating division/remainder for int64 operands, exact for
% |a|,|b| < 2^53; b == 0 errors (a silent 0 would hide a C div-by-zero
% crash). Quotient truncates toward zero; the remainder takes the sign
% of the dividend (xc.c `a / b` / `a % b` semantics).
% (Integer division of typed operands is not portable across MATLAB
% versions, so the VM computes it from exact double math.)
if b == 0
    fail('division by zero');
end
a = double(a);
b = double(b);
r = mod(a, b);
if a < 0 && r ~= 0
    r = r - b;
end
q = int64((a - r) / b);   % exact: quotient is an integer < 2^53
r = int64(r);
end

function nfail = vm_selftest()
% vm_selftest — Phase 1 VM tests: hand-assembled programs built straight
% into the text segment, run on vm_eval, exit value compared. Prints
% PASS/FAIL per case and returns the number of failures. Invoked via
% xc('--vm-selftest').
global text ti pc bp sp ax cycle mem poolsize stack_base

% opcodes (xc.c enum order — keep in sync with opname)
LEA=0; IMM=1; JMP=2; CALL=3; JZ=4; JNZ=5; ENT=6; ADJ=7; LEV=8; LI=9; LC=10;
SI=11; SC=12; PUSH=13;
OR=14; XOR=15; AND=16; EQ=17; NE=18; LT=19; GT=20; LE=21; GE=22;
SHL=23; SHR=24; ADD=25; SUB=26; MUL=27; DIV=28; MOD=29;
EXIT=37;

nfail = 0;
SB = stack_base;

% --- 1) IMM/PUSH/MUL/ADD ---
nfail = nfail + run_case([IMM 1 PUSH IMM 2 PUSH IMM 3 MUL ADD PUSH EXIT], 7, ...
                         'IMM/PUSH/MUL/ADD -> 7');

% --- 2) arithmetic / shift / bitwise / comparison battery ---
nfail = nfail + run_case([IMM 7 PUSH IMM 2 DIV PUSH EXIT], 3, 'DIV 7/2 -> 3');
nfail = nfail + run_case([IMM 7 PUSH IMM 2 MOD PUSH EXIT], 1, 'MOD 7%%2 -> 1');
nfail = nfail + run_case([IMM -7 PUSH IMM 2 DIV PUSH EXIT], -3, ...
                         'DIV -7/2 -> -3 (trunc)');
nfail = nfail + run_case([IMM -7 PUSH IMM 2 MOD PUSH EXIT], -1, ...
                         'MOD -7%%2 -> -1');
nfail = nfail + run_case([IMM 5 PUSH IMM 3 SUB PUSH EXIT], 2, 'SUB 5-3 -> 2');
nfail = nfail + run_case([IMM 1 PUSH IMM 40 SHL PUSH EXIT], 2^40, 'SHL 1<<40');
nfail = nfail + run_case([IMM 2^40 PUSH IMM 40 SHR PUSH EXIT], 1, 'SHR 2^40>>40');
nfail = nfail + run_case([IMM -16 PUSH IMM 1 SHR PUSH EXIT], -8, ...
                         'SHR -16>>1 arithmetic');
nfail = nfail + run_case([IMM 12 PUSH IMM 10 AND PUSH EXIT], 8, 'AND 12&10 -> 8');
nfail = nfail + run_case([IMM 12 PUSH IMM 10 OR PUSH EXIT], 14, 'OR 12|10 -> 14');
nfail = nfail + run_case([IMM 12 PUSH IMM 10 XOR PUSH EXIT], 6, 'XOR 12^10 -> 6');
nfail = nfail + run_case([IMM 3 PUSH IMM 5 EQ PUSH EXIT], 0, 'EQ 3==5 -> 0');
nfail = nfail + run_case([IMM 3 PUSH IMM 3 EQ PUSH EXIT], 1, 'EQ 3==3 -> 1');
nfail = nfail + run_case([IMM 3 PUSH IMM 5 NE PUSH EXIT], 1, 'NE 3!=5 -> 1');
nfail = nfail + run_case([IMM 3 PUSH IMM 5 LT PUSH EXIT], 1, 'LT 3<5 -> 1');
nfail = nfail + run_case([IMM 3 PUSH IMM 5 LE PUSH EXIT], 1, 'LE 3<=5 -> 1');
nfail = nfail + run_case([IMM 5 PUSH IMM 5 LE PUSH EXIT], 1, 'LE 5<=5 -> 1');
nfail = nfail + run_case([IMM 5 PUSH IMM 3 GT PUSH EXIT], 1, 'GT 5>3 -> 1');
nfail = nfail + run_case([IMM 5 PUSH IMM 5 GE PUSH EXIT], 1, 'GE 5>=5 -> 1');

% --- 3) JZ/JNZ/JMP loop: counter in mem slot 0, 1..5, exit 5 ---
% layout: IMM 0 PUSH IMM 0 SI | loop: IMM 0 LI PUSH IMM 1 ADD IMM 0 PUSH SI |
%         IMM 0 LI PUSH IMM 5 SUB | JZ exit | JMP loop | exit: IMM 0 LI PUSH EXIT
loop = [IMM 0 PUSH IMM 0 SI ...                     % init: M = 0
        IMM 0 PUSH LI PUSH IMM 1 ADD SI ...         % M = M + 1 (addr pushed first)
        IMM 0 LI PUSH IMM 5 SUB ...                 % ax = M - 5
        JZ 27 JMP 7 ...                             % exit if M==5, else loop
        IMM 0 LI PUSH EXIT];                        % exit: return M
nfail = nfail + run_case(loop, 5, 'JZ/JNZ/JMP loop -> 5');

% --- 4) frame round-trip: ENT/LEA/PUSH/IMM/SI/LEA/LI/LEV -> 42 ---
% sp starts 4 words below stack_base: ENT pushes old bp at SB-40, bp =
% SB-40, frame spans SB-56..SB-24; LEA 2 targets SB-24 (in range). LEV
% restores pc from the pre-stored slot at SB-32 (value 14 = 1-based index
% of the PUSH after LEV).
frame = [ENT 2 LEA 2 PUSH IMM 42 SI LEA 2 LI LEV PUSH EXIT];
nfail = nfail + run_case(frame, 42, 'ENT/LEA/SI/LI/LEV frame -> 42', ...
                         'sp', SB-32, 'store', {SB-32, 14});

% --- 5) LC/SC byte stores ---
nfail = nfail + run_case([IMM 0 PUSH IMM 65 SC IMM 0 LC PUSH EXIT], 65, ...
                         'SC/LC byte round-trip -> 65');
nfail = nfail + run_case([IMM 0 PUSH IMM 300 SC IMM 0 LC PUSH EXIT], 44, ...
                         'SC stores low byte (300 -> 44)');

% --- 6) CALL/ADJ: callee ENT/LEV, caller CALL + ADJ 1 -> 7 ---
% callee ENT is prog index 9 (operand = 9); caller pushes an arg, CALLs
% (returning to ADJ), ADJ pops it.
call = [IMM 99 CALL 9 ADJ 1 PUSH EXIT ENT 0 IMM 7 LEV];
nfail = nfail + run_case(call, 7, 'CALL/ADJ value round-trip -> 7', ...
                         'sp', SB-32);

% --- 7) DIV by zero errors (zero-divisor guard) ---
try
    run_case([IMM 1 PUSH IMM 0 DIV PUSH EXIT], 0, 'DIV by zero');
    fprintf('FAIL  DIV by zero does not error\n');
    nfail = nfail + 1;
catch e
    if ~isempty(strfind(e.message, 'division by zero'))
        fprintf('PASS  DIV by zero errors\n');
    else
        fprintf('FAIL  DIV by zero (wrong message: %s)\n', e.message);
        nfail = nfail + 1;
    end
end

fprintf('vm_selftest: %d cases, %d failed\n', 26, nfail);
end

function nf = run_case(prog, expected, name, varargin)
% run_case — assemble `prog` (flat opcode/operand array) into the text
% segment, apply varargin key/value setup ('sp', 'bp', 'pc', 'store'
% {addr,val}), run vm_eval, compare the EXIT value with `expected`.
global text ti pc bp sp ax cycle mem poolsize stack_base

nf = 0;
text = zeros(1, 32768, 'int64');
ti = 0;
for k = 1:numel(prog)
    ti = ti + 1;
    text(ti+1) = int64(prog(k));
end
mem = zeros(1, 3*poolsize, 'uint8');
sp = stack_base;
bp = stack_base;
pc = 2;   % first instruction at slot 1 (slot 0 unused, mirroring xc.c) -> text(2)
ax = int64(0);
cycle = 0;

% Option scan. `for k = 1:2:numel(varargin)` is fine again — the runtime
% used to evaluate 1:2:0 as [1] (DIV-8), fixed in v1.2.39.
for k = 1:2:numel(varargin)
    switch varargin{k}
        case 'sp'
            sp = varargin{k+1};
        case 'bp'
            bp = varargin{k+1};
        case 'pc'
            pc = varargin{k+1};
        case 'store'
            w = varargin{k+1};
            word_store(w{1}, w{2});
        otherwise
            fail(sprintf('run_case: unknown option %s', varargin{k}));
    end
end

got = vm_eval();
if double(got) == expected
    fprintf('PASS  %s\n', name);
else
    fprintf('FAIL  %s (exit %d, expected %d)\n', name, double(got), expected);
    nf = 1;
end
end

% ---------------------------------------------------------------------------
% Phase 2: the lexer (port of xc.c next())
% ---------------------------------------------------------------------------

function next()
% next — lex the next token (port of xc.c next()). Reads global src (a
% NUL-terminated char vector) at 0-based index si. Sets token (a char code
% or a token-enum value — see below) and token_val (number value, or the
% data address for a string literal). New identifiers are inserted into the
% symbol table and current_id is set to the row.
%
% token enum (xc.c): Num=128 Fun=129 Sys=130 Glo=131 Loc=132 Id=133,
% Char=134 Else=135 Enum=136 If=137 Int=138 Return=139 Sizeof=140 While=141,
% Assign=142 Cond=143 Lor=144 Lan=145 Or=146 Xor=147 And=148 Eq=149 Ne=150,
% Lt=151 Gt=152 Le=153 Ge=154 Shl=155 Shr=156 Add=157 Sub=158 Mul=159
% Div=160 Mod=161 Inc=162 Dec=163 Brak=164; single-char tokens keep their
% ASCII code.
global token token_val src si line current_id symbols symbol_names ...
       data mem assembly old_src old_text text ti

while true
    if si >= numel(src)
        token = 0;          % past the NUL padding: end of input
        return;
    end
    token = double(src(si+1));
    si = si + 1;

    if token == 10                       % '\n'
        nl_line();
    elseif token == 35                   % '#': skip the macro line
        while si < numel(src)
            c = double(src(si+1));
            if c == 0 || c == 10
                break;
            end
            si = si + 1;
        end
    elseif (token >= 97 && token <= 122) || (token >= 65 && token <= 90) || token == 95
        % identifier: consume ident chars, hash, linear-search the table
        last_pos = si - 1;
        hash = int64(token);
        while si < numel(src)
            c = double(src(si+1));
            if ~((c >= 97 && c <= 122) || (c >= 65 && c <= 90) || ...
                 (c >= 48 && c <= 57) || c == 95)
                break;
            end
            hash = hash * int64(147) + int64(c);
            si = si + 1;
        end
        idstr = src(last_pos+1 : si);
        k = 1;
        while k <= size(symbols,1) && symbols(k,1) ~= 0
            if symbols(k,2) == hash && strcmp(symbol_names{k}, idstr)
                current_id = k;
                token = double(symbols(k,1));
                return;
            end
            k = k + 1;
        end
        if k > size(symbols,1)
            fail('symbol table overflow');
        end
        symbols(k,1) = int64(133);   % Token = Id
        symbols(k,2) = hash;
        symbol_names{k} = idstr;
        current_id = k;
        token = 133;                 % Id
        return;
    elseif token >= 48 && token <= 57
        % number: dec (1-9...), hex (0x...), oct (0...)
        token_val = int64(token - 48);
        if token_val > 0
            while si < numel(src)
                c = double(src(si+1));
                if c < 48 || c > 57
                    break;
                end
                token_val = token_val * int64(10) + int64(c - 48);
                si = si + 1;
            end
        elseif si < numel(src) && (double(src(si+1)) == 120 || double(src(si+1)) == 88)
            % hex (0x / 0X)
            si = si + 1;
            while si < numel(src)
                t = double(src(si+1));
                if ~((t >= 48 && t <= 57) || (t >= 97 && t <= 102) || (t >= 65 && t <= 70))
                    break;
                end
                token_val = token_val * int64(16) + int64(mod(t,16) + 9*(t >= 65));
                si = si + 1;
            end
        else
            % oct (0...7)
            while si < numel(src)
                c = double(src(si+1));
                if c < 48 || c > 55
                    break;
                end
                token_val = token_val * int64(8) + int64(c - 48);
                si = si + 1;
            end
        end
        token = 128;   % Num
        return;
    elseif token == 47                   % '/'
        if si < numel(src) && double(src(si+1)) == 47
            % '//' comment: skip to end of line
            while si < numel(src)
                c = double(src(si+1));
                if c == 0 || c == 10
                    break;
                end
                si = si + 1;
            end
        elseif si < numel(src) && double(src(si+1)) == 42
            % '/*' block comment: skip to '*/', counting newlines inside
            % (post-parity addition; the reference dialect lacks this)
            si = si + 1;   % consume '*'
            while true
                if si >= numel(src) - 1
                    fail('unterminated block comment');
                end
                c = double(src(si+1));
                if c == 42 && double(src(si+2)) == 47
                    si = si + 2;         % consume '*/'
                    break;
                elseif c == 10
                    si = si + 1;
                    nl_line();
                else
                    si = si + 1;
                end
            end
        else
            token = 160;   % Div
            return;
        end
    elseif token == 34 || token == 39    % '"' string or '\'' char literal
        q = token;
        last_pos = data;
        token_val = 0;                   % C: token_val is the loop's char var
        while si < numel(src)
            v = double(src(si+1));
            if v == 0 || v == q
                break;
            end
            si = si + 1;
            if v == 92                   % '\' escape (only 'n' -> newline)
                if si >= numel(src)
                    break;
                end
                v = double(src(si+1));
                si = si + 1;
                if v == 110              % 'n'
                    v = 10;
                end
            end
            token_val = v;
            if q == 34
                mem(data+1) = uint8(v);  % 0-based byte address -> 1-based index
                data = data + 1;
            end
        end
        if si < numel(src) && double(src(si+1)) == q
            si = si + 1;                 % skip the closing quote
        end
        if q == 34
            % NUL-terminate the stored literal: consecutive strings would
            % otherwise bleed into each other when align8 pads nothing
            % (post-parity %s fix — the reference relies on zeroed pages)
            mem(data+1) = uint8(0);
            data = data + 1;
            token_val = last_pos;        % string: token_val = data address
        else
            token = 128;                 % char literal -> Num (token_val = char)
        end
        return;
    elseif token == 61                   % '='
        if si < numel(src) && double(src(si+1)) == 61
            si = si + 1;
            token = 149;                 % Eq
        else
            token = 142;                 % Assign
        end
        return;
    elseif token == 43                   % '+'
        if si < numel(src) && double(src(si+1)) == 43
            si = si + 1;
            token = 162;                 % Inc
        else
            token = 157;                 % Add
        end
        return;
    elseif token == 45                   % '-'
        if si < numel(src) && double(src(si+1)) == 45
            si = si + 1;
            token = 163;                 % Dec
        else
            token = 158;                 % Sub
        end
        return;
    elseif token == 33                   % '!'
        if si < numel(src) && double(src(si+1)) == 61
            si = si + 1;
            token = 150;                 % Ne
        end
        return;
    elseif token == 60                   % '<'
        if si < numel(src) && double(src(si+1)) == 61
            si = si + 1;
            token = 153;                 % Le
        elseif si < numel(src) && double(src(si+1)) == 60
            si = si + 1;
            token = 155;                 % Shl
        else
            token = 151;                 % Lt
        end
        return;
    elseif token == 62                   % '>'
        if si < numel(src) && double(src(si+1)) == 61
            si = si + 1;
            token = 154;                 % Ge
        elseif si < numel(src) && double(src(si+1)) == 62
            si = si + 1;
            token = 156;                 % Shr
        else
            token = 152;                 % Gt
        end
        return;
    elseif token == 124                  % '|'
        if si < numel(src) && double(src(si+1)) == 124
            si = si + 1;
            token = 144;                 % Lor
        else
            token = 146;                 % Or
        end
        return;
    elseif token == 38                   % '&'
        if si < numel(src) && double(src(si+1)) == 38
            si = si + 1;
            token = 145;                 % Lan
        else
            token = 148;                 % And
        end
        return;
    elseif token == 94                   % '^'
        token = 147;                     % Xor
        return;
    elseif token == 37                   % '%'
        token = 161;                     % Mod
        return;
    elseif token == 42                   % '*'
        token = 159;                     % Mul
        return;
    elseif token == 91                   % '['
        token = 164;                     % Brak
        return;
    elseif token == 63                   % '?'
        token = 143;                     % Cond
        return;
    elseif token == 126 || token == 59 || token == 123 || token == 125 || ...
           token == 40 || token == 41 || token == 93 || token == 44 || token == 58
        return;                          % '~ ; { } ( ) ] , :' — token = char code
    end
    % unrecognized character: skip and continue
end
end

function seed_symbols()
% seed_symbols — port of xc.c main's keyword/library seeding. Lexes the
% keyword+syscall string so the identifiers land in the symbol table:
% keywords get Token = Char..While, syscalls get Class=Sys/Type=INT/
% Value=opcode, 'void' becomes Void (165), 'main' is recorded as idmain.
global src si current_id symbols symbol_names idmain

src = ['char else enum if int return sizeof while ', ...
       'open read close printf malloc memset memcmp exit void main', ...
       char(0), char(0)];
si = 0;
i = 134;                                % Char
while i <= 141                          % While
    next();
    symbols(current_id, 1) = int64(i);
    i = i + 1;
end
i = 30;                                 % OPEN
while i <= 37                           % EXIT
    next();
    symbols(current_id, 4) = int64(1);   % Type = INT
    symbols(current_id, 5) = int64(130); % Class = Sys
    symbols(current_id, 6) = int64(i);   % Value = opcode
    i = i + 1;
end
next();                                  % 'void' -> Token = Void (post-parity)
symbols(current_id, 1) = int64(165);
next();                                  % 'main'
idmain = current_id;
end

function nfail = lex_selftest()
% lex_selftest — Phase 2 lexer tests: token streams, number values, string
% storage, comments/# skipping, identifier lookup, -s dump. Invoked via
% xc('--lex-selftest'); returns the number of failed cases.
nfail = 0;

% token constants (xc.c enum — see next())
Num=128; Id=133;
Int=138; Return=139;

% 1) seeded keywords + basic program
nfail = nfail + lex_case('int main() { return 2; }', ...
    [Int Id 40 41 123 Return Num 59 125], 'keywords + basic program', ...
    'seeded', 1);

% 2) all multi-char operators
nfail = nfail + lex_case(...
    'a==b!=c<d>e<=f>=g<<h>>i+j-k*l/m%n&o|p^q&&r||s', ...
    [Id 149 Id 150 Id 151 Id 152 Id 153 Id 154 Id 155 Id 156 Id 157 Id 158 ...
     Id 159 Id 160 Id 161 Id 148 Id 146 Id 147 Id 145 Id 144 Id], ...
    'all operators');

% 3) inc/dec/not/assign/ternary/tilde/brak + char tokens
nfail = nfail + lex_case('i++j--!a!=b=c?d:e~f[2]', ...
    [Id 162 Id 163 33 Id 150 Id 142 Id 143 Id 58 Id 126 Id 164 Num 93], ...
    'inc/dec/not/ternary/tilde/brak');

% 4) numbers dec/hex/oct
nfail = nfail + lex_case('0 123 0x1F 017 0X2a 65535', ...
    [Num Num Num Num Num Num], 'numbers dec/hex/oct', ...
    'vals', [0 123 31 15 42 65535]);

% 5) strings + char literals (escape: \n only)
BS = char(92); SQ = char(39);
% strings now NUL-terminated in mem: "abc" at 0-3, "a\nb" at 4-7
nfail = nfail + lex_case(['"abc" "a' BS 'nb" ' SQ 'x' SQ ' ' SQ BS 'n' SQ ' ' SQ BS BS SQ], ...
    [34 34 Num Num Num], 'strings and char literals', ...
    'vals', [0 4 120 10 92], 'mem', {0, [97 98 99 0 97 10 98 0]});

% 6) comments and # skip + line counting
nfail = nfail + lex_case(['int a; // comment' char(10) '#define X 1' char(10) 'int b;'], ...
    [Int Id 59 Int Id 59], 'comments/# skip + line count', ...
    'seeded', 1, 'line', 3);

% 7) identifier insert + hash lookup
nfail = nfail + lex_case('foo foo bar', [Id Id Id], 'identifier lookup');

% 8) -s line dump fires on newline (content asserted via run_tests evalc)
nfail = nfail + lex_case(['int x;' char(10) 'int y;'], [Int Id 59 Int Id 59], ...
    '-s line dump', 'seeded', 1, 'assembly', 1);

% 9) block comments (post-parity), spanning lines
nfail = nfail + lex_case(['int a; /* comment' char(10) 'more */ int b;'], ...
    [Int Id 59 Int Id 59], 'block comments + line count', ...
    'seeded', 1, 'line', 2);

fprintf('lex_selftest: %d cases, %d failed\n', 9, nfail);
end

function nf = lex_case(srcstr, expected, name, varargin)
% lex_case — reset the lexer state, optionally seed the symbol table,
% tokenize srcstr, and compare the token stream with `expected`.
% Options (key/value pairs): 'vals' expected token_vals; 'seeded' nonzero
% to run seed_symbols() first; 'assembly' nonzero to enable the -s dump;
% 'line' expected final line counter; 'mem' {addr, bytes} to verify bytes
% stored in the data region.
global src si line token token_val current_id symbols symbol_names ...
       array_strides data mem text ti old_src old_text assembly poolsize

nf = 0;
% reset lexer state
line = 1;
token = 0;
token_val = 0;
current_id = 0;
data = 0;
mem = zeros(1, 3*poolsize, 'uint8');
text = zeros(1, 32768, 'int64');
ti = 0;
old_src = 0;
old_text = 0;
assembly = 0;
symbols = zeros(3276, 10, 'int64');
symbol_names = cell(3276, 1);
array_strides = cell(3276, 1);

evals = [];
eline = [];
mc = [];
for k = 1:2:numel(varargin)
    switch varargin{k}
        case 'vals'
            evals = varargin{k+1};
        case 'seeded'
            if varargin{k+1} ~= 0
                seed_symbols();
            end
        case 'assembly'
            assembly = varargin{k+1};
        case 'line'
            eline = varargin{k+1};
        case 'mem'
            mc = varargin{k+1};
        otherwise
            fail(sprintf('lex_case: unknown option %s', varargin{k}));
    end
end
src = [srcstr, char(0), char(0)];
si = 0;

toks = [];
vals = [];
while true
    next();
    if token == 0
        break;
    end
    toks = [toks, token];
    vals = [vals, token_val];
end

if ~isequal(toks, expected)
    fprintf('FAIL  %s (tokens [%s], expected [%s])\n', name, ...
            num2str(toks), num2str(expected));
    nf = 1;
elseif ~isempty(evals) && ~isequal(double(vals), evals)
    fprintf('FAIL  %s (vals [%s], expected [%s])\n', name, ...
            num2str(double(vals)), num2str(evals));
    nf = 1;
elseif ~isempty(eline) && line ~= eline
    fprintf('FAIL  %s (line %d, expected %d)\n', name, line, eline);
    nf = 1;
elseif ~isempty(mc) && ~isequal(double(mem(mc{1}+1 : mc{1}+numel(mc{2}))), mc{2})
    fprintf('FAIL  %s (mem at %d: [%s], expected [%s])\n', name, mc{1}, ...
            num2str(double(mem(mc{1}+1 : mc{1}+numel(mc{2})))), num2str(mc{2}));
    nf = 1;
else
    fprintf('PASS  %s\n', name);
end
end

% ---------------------------------------------------------------------------
% Phase 3: the parser (port of xc.c match/expression/statement/declarations)
% ---------------------------------------------------------------------------

function v = pick(cond, a, b)
% pick — inline ternary replacement (MATLAB has no ?: operator).
if cond
    v = a;
else
    v = b;
end
end

function s = array_strides_of(dims, elem)
% array_strides_of — per-level byte strides for an array with dims and
% elem-byte elements: s(j) = elem * prod(dims(j+1:end)), s(end) = elem.
% For int[2][3] (elem 8): s = [24 8] — a[i] advances 24 bytes, a[i][j] 8.
n = numel(dims);
s = zeros(1, n);
acc = elem;
for j = n:-1:1
    s(j) = acc;
    acc = acc * dims(j);
end
end

function vals = parse_braces(dims, lvl)
% parse_braces — parse one brace-enclosed initializer list filling the
% sub-array dims(lvl:end); returns the flat (row-major) values, zero-padded.
% C 6.7.9 brace elision: a nested group covers the remainder of the current
% subobject at its start position; scalars continue the flat sequence.
global token line
S = prod(dims(min(lvl, numel(dims)):end));
vals = zeros(1, S);
i = 0;
while token ~= 125          % '}'
    if token == 123         % '{': nested group
        match(123);
        if lvl < numel(dims)
            s = prod(dims(lvl+1:end));   % subobject size at the next level
            extent = s - mod(i, s);      % remainder of the current subobject
        else
            extent = S - i;              % scalar level: fills the rest
        end
        sub = parse_braces(dims, lvl + 1);
        match(125);
        vals(i+1 : i+extent) = sub(1:extent);
        i = i + extent;
    else
        v = double(const_expr());
        if i >= S
            fail(sprintf('%d: too many array initializers', line));
        end
        vals(i+1) = v;
        i = i + 1;
    end
    if token == 44          % ','
        match(44);
    end
end
end

function a = slot_after()
% slot_after — reserve the next text slot for a backpatch (C's `b = ++text`
% after emitting a jump: the operand slot is skipped by the increment, so
% the next emit lands past it). Returns the reserved slot (0-based) and
% advances ti so the following emit writes at a+1, not at a.
global ti
a = ti + 1;
ti = ti + 1;
end

function v = const_expr()
% const_expr — evaluate a compile-time constant initializer (post-parity):
% a number literal (optionally sign-flipped), a char literal (lexed as Num),
% a string literal's data address, or an enum constant. Advances the lexer.
global token token_val current_id symbols
Num=128; Id=133; Sub=158; Add=157;
if token == Sub || token == Add
    neg = (token == Sub);
    match(token);
    if token ~= Num
        fail('bad constant initializer');
    end
    v = token_val;
    if neg
        v = -v;
    end
    next();
elseif token == Num
    v = token_val;
    next();
elseif token == 34          % '"': string literal -> its data address
    v = token_val;
    next();
elseif token == Id && symbols(current_id,5) == 128   % enum constant
    v = symbols(current_id,6);
    next();
else
    fail(sprintf('bad constant initializer (token %d)', token));
end
end

function match(tk)
% match — consume the current token if it equals tk, else fail (xc.c match()).
global token line
if token == tk
    next();
else
    fail(sprintf('%d: expected token: %d', line, tk));
end
end

function nl_line()
% nl_line — process a consumed '\n' during lexing: -s source-line dump +
% line counter. Shared by the outer lexer loop and multi-line block
% comments.
global assembly line old_src old_text src si text ti
if assembly
    % -s dump: source line + instructions emitted since the last line.
    % The runtime's fprintf ignores %8.4s width/precision, so the mnemonic
    % column is padded manually to match the reference.
    fprintf('%d: %s', line, src(old_src+1 : si));
    old_src = si;
    while old_text < ti
        old_text = old_text + 1;
        % %8.4s-equivalent: all mnemonics are 3 or 4 chars
        mn = opname(text(old_text+1));
        if numel(mn) == 3
            fprintf('    %s ', mn);
        else
            fprintf('    %s', mn);
        end
        if text(old_text+1) <= 7   % ADJ: ops with an operand slot
            old_text = old_text + 1;
            fprintf(' %d\n', text(old_text+1));
        else
            fprintf('\n');
        end
    end
end
line = line + 1;
end

function expression(level)
% expression — recursive-descent expression parser (port of xc.c expression()).
% Parses a unit (literal, id, call, cast, unary), then binary/postfix
% operators while token >= level (token enum values are the precedence
% levels). Emits VM instructions; expr_type tracks the C type (0=char,
% 1=int, 2+=pointer).
global token token_val line current_id symbols expr_type index_of_bp ...
       text ti data unit_was_array bstrides array_strides

% tokens (xc.c enum)
Num=128; Id=133; Int=138; Sizeof=140;
Assign=142; Cond=143; Lor=144; Lan=145; Or=146; Xor=147; And=148;
Eq=149; Ne=150; Lt=151; Gt=152; Le=153; Ge=154; Shl=155; Shr=156;
Add=157; Sub=158; Mul=159; Div=160; Mod=161; Inc=162; Dec=163; Brak=164;
% opcodes (xc.c enum)
LEA=0; IMM=1; JMP=2; CALL=3; JZ=4; JNZ=5; ENT=6; ADJ=7; LEV=8; LI=9; LC=10;
SI=11; SC=12; PUSH=13; OR=14; XOR=15; AND=16; EQ=17; NE=18; LT=19; GT=20;
LE=21; GE=22; SHL=23; SHR=24; ADD=25; SUB=26; MUL=27; DIV=28; MOD=29;
% types and classes
CHAR=0; INT=1; PTR=2;
Sys=130; Fun=129; Glo=131; Loc=132;

if token == 0
    fail(sprintf('%d: unexpected token EOF of expression', line));
end

% ---- unit / unary ----
unit_was_array = 0;   % set only when the unit is a bare array name (C2)
bstrides = [];        % set only by an array-name unit (multi-dim strides)
if token == Num
    match(Num);
    emit(IMM);
    emit(token_val);
    expr_type = INT;
elseif token == 34                  % '"'
    emit(IMM);
    emit(token_val);
    match(34);
    while token == 34               % consecutive string literals
        match(34);
    end
    data = align8(data);
    expr_type = PTR;
elseif token == Sizeof
    match(Sizeof);
    match(40);                      % '('
    if token == Id && symbols(current_id,4) >= 4096
        % sizeof(array name) = total bytes (post-parity)
        match(Id);
        match(41);
        emit(IMM);
        emit(symbols(current_id,10));
        expr_type = INT;
    elseif token == Int || token == 134
        expr_type = INT;
        if token == Int
            match(Int);
        else
            match(134);             % Char
            expr_type = CHAR;
        end
        while token == Mul
            match(Mul);
            expr_type = expr_type + PTR;
        end
        match(41);                  % ')'
        emit(IMM);
        emit(pick(expr_type == CHAR, 1, 8));   % sizeof(char)=1, sizeof(int)=8
        expr_type = INT;
    else
        % sizeof(<expression>): parse for its type, drop the emitted code
        % (C does not evaluate the operand of sizeof)
        saved_ti = ti;
        expression(Assign);
        match(41);
        sz = pick(expr_type == CHAR, 1, 8);
        ti = saved_ti;
        emit(IMM);
        emit(sz);
        expr_type = INT;
    end
elseif token == Id
    match(Id);
    id = current_id;
    if token == 40                  % '(': function call
        match(40);
        tmp = 0;                    % argument count
        while token ~= 41           % ')'
            expression(Assign);
            emit(PUSH);
            tmp = tmp + 1;
            if token == 44          % ','
                match(44);
            end
        end
        match(41);
        if symbols(id,5) == Sys
            emit(symbols(id,6));    % syscall opcode
        elseif symbols(id,5) == Fun
            emit(CALL);
            emit(symbols(id,6));
        else
            fail(sprintf('%d: bad function call', line));
        end
        if tmp > 0
            emit(ADJ);
            emit(tmp);
        end
        expr_type = symbols(id,4);
        bstrides = [];   % function results are scalars
    elseif symbols(id,5) == Num     % enum constant
        emit(IMM);
        emit(symbols(id,6));
        expr_type = INT;
    else
        % variable (or array name — post-parity)
        idtype = symbols(id,4);
        if idtype >= 4096            % ARRAY_FLAG: decays to a pointer
            if symbols(id,5) == Loc
                emit(LEA);
                emit(index_of_bp - symbols(id,6));
            elseif symbols(id,5) == Glo
                emit(IMM);
                emit(symbols(id,6));
            else
                fail(sprintf('%d: undefined variable', line));
            end
            expr_type = double(idtype - 4096) + PTR;   % pointer to element
            unit_was_array = 1;
            bstrides = array_strides{id};   % per-level byte strides
        else
            if symbols(id,5) == Loc
                emit(LEA);
                emit(index_of_bp - symbols(id,6));
            elseif symbols(id,5) == Glo
                emit(IMM);
                emit(symbols(id,6));
            else
                fail(sprintf('%d: undefined variable', line));
            end
            expr_type = double(idtype);
            emit(pick(expr_type == CHAR, LC, LI));
        end
    end
elseif token == 40                  % '(': cast or parenthesis
    match(40);
    if token == Int || token == 134 % Char
        tmp = pick(token == 134, CHAR, INT);
        match(token);
        while token == Mul
            match(Mul);
            tmp = tmp + PTR;
        end
        match(41);                  % ')'
        expression(Inc);
        expr_type = tmp;
    else
        expression(Assign);
        match(41);                  % ')'
    end
    bstrides = [];
elseif token == Mul                 % dereference *addr
    match(Mul);
    expression(Inc);
    if expr_type >= PTR
        expr_type = expr_type - PTR;
    else
        fail(sprintf('%d: bad dereference', line));
    end
    emit(pick(expr_type == CHAR, LC, LI));
    bstrides = [];
elseif token == And                 % address-of
    match(And);
    expression(Inc);
    if text(ti+1) == LC || text(ti+1) == LI
        ti = ti - 1;                % drop the load; ax holds the address
        expr_type = expr_type + PTR;
        bstrides = [];
    elseif ~unit_was_array && isempty(bstrides)
        fail(sprintf('%d: bad address of', line));
    end
    % array name or multi-dim row: address already in ax — no-op
    bstrides = [];   % & yields a plain pointer
elseif token == 33                  % '!': not
    match(33);
    expression(Inc);
    emit(PUSH);
    emit(IMM);
    emit(0);
    emit(EQ);
    expr_type = INT;
    bstrides = [];
elseif token == 126                 % '~': bitwise not
    match(126);
    expression(Inc);
    emit(PUSH);
    emit(IMM);
    emit(-1);
    emit(XOR);
    expr_type = INT;
    bstrides = [];
elseif token == Add                 % unary +
    match(Add);
    expression(Inc);
    expr_type = INT;
    bstrides = [];
elseif token == Sub                 % unary -
    match(Sub);
    if token == Num
        emit(IMM);
        emit(-token_val);
        match(Num);
    else
        emit(IMM);
        emit(-1);
        emit(PUSH);
        expression(Inc);
        emit(MUL);
    end
    expr_type = INT;
    bstrides = [];
elseif token == Inc || token == Dec % pre-increment/decrement
    tmp = token;
    match(token);
    expression(Inc);
    if text(ti+1) == LC
        text(ti+1) = PUSH;          % duplicate the address
        emit(LC);
    elseif text(ti+1) == LI
        text(ti+1) = PUSH;
        emit(LI);
    else
        fail(sprintf('%d: bad lvalue of pre-increment', line));
    end
    emit(PUSH);
    emit(IMM);
    emit(pick(expr_type > PTR, 8, 1));
    emit(pick(tmp == Inc, ADD, SUB));
    emit(pick(expr_type == CHAR, SC, SI));
    bstrides = [];
else
    fail(sprintf('%d: bad expression', line));
end

% ---- binary / postfix operators ----
while token >= level
    unit_was_array = 0;   % any operator makes the expression non-array (C2)
    sav_stride = bstrides;   % left operand's per-level strides (multi-dim)
    bstrides = [];           % default: ops yield scalars/plain pointers
    tmp = expr_type;
    if token == Assign
        match(Assign);
        if text(ti+1) == LC || text(ti+1) == LI
            text(ti+1) = PUSH;      % save the lvalue address
        else
            fail(sprintf('%d: bad lvalue in assignment', line));
        end
        expression(Assign);
        expr_type = tmp;
        emit(pick(expr_type == CHAR, SC, SI));
    elseif token == Cond
        match(Cond);
        emit(JZ);
        addr = slot_after();
        expression(Assign);
        if token == 58              % ':'
            match(58);
        else
            fail(sprintf('%d: missing colon in conditional', line));
        end
        text(addr+1) = ti + 3;      % jump past the JMP below
        emit(JMP);
        addr = slot_after();
        expression(Cond);
        text(addr+1) = ti + 1;      % jump past the true branch
    elseif token == Lor
        match(Lor);
        emit(JNZ);
        addr = slot_after();
        expression(Lan);
        text(addr+1) = ti + 1;
        expr_type = INT;
    elseif token == Lan
        match(Lan);
        emit(JZ);
        addr = slot_after();
        expression(Or);
        text(addr+1) = ti + 1;
        expr_type = INT;
    elseif token == Or
        match(Or);
        emit(PUSH); expression(Xor); emit(OR);
        expr_type = INT;
    elseif token == Xor
        match(Xor);
        emit(PUSH); expression(And); emit(XOR);
        expr_type = INT;
    elseif token == And
        match(And);
        emit(PUSH); expression(Eq); emit(AND);
        expr_type = INT;
    elseif token == Eq
        match(Eq);
        emit(PUSH); expression(Ne); emit(EQ);
        expr_type = INT;
    elseif token == Ne
        match(Ne);
        emit(PUSH); expression(Lt); emit(NE);
        expr_type = INT;
    elseif token == Lt
        match(Lt);
        emit(PUSH); expression(Shl); emit(LT);
        expr_type = INT;
    elseif token == Gt
        match(Gt);
        emit(PUSH); expression(Shl); emit(GT);
        expr_type = INT;
    elseif token == Le
        match(Le);
        emit(PUSH); expression(Shl); emit(LE);
        expr_type = INT;
    elseif token == Ge
        match(Ge);
        emit(PUSH); expression(Shl); emit(GE);
        expr_type = INT;
    elseif token == Shl
        match(Shl);
        emit(PUSH); expression(Add); emit(SHL);
        expr_type = INT;
    elseif token == Shr
        match(Shr);
        emit(PUSH); expression(Add); emit(SHR);
        expr_type = INT;
    elseif token == Add
        match(Add);
        emit(PUSH);
        expression(Mul);
        expr_type = tmp;
        if expr_type > PTR || numel(sav_stride) > 1
            % pointer/array: scale the int by the element stride
            if ~isempty(sav_stride)
                stride = sav_stride(1);
            else
                stride = 8;
            end
            emit(PUSH);
            emit(IMM);
            emit(stride);
            emit(MUL);
        end
        emit(ADD);
    elseif token == Sub
        match(Sub);
        emit(PUSH);
        expression(Mul);
        if tmp > PTR && tmp == expr_type
            % pointer - pointer: difference in elements
            if ~isempty(sav_stride)
                stride = sav_stride(1);
            else
                stride = 8;
            end
            emit(SUB);
            emit(PUSH);
            emit(IMM);
            emit(stride);
            emit(DIV);
            expr_type = INT;
        elseif tmp > PTR || numel(sav_stride) > 1
            % pointer - int: scale the int by the element stride
            if ~isempty(sav_stride)
                stride = sav_stride(1);
            else
                stride = 8;
            end
            emit(PUSH);
            emit(IMM);
            emit(stride);
            emit(MUL);
            emit(SUB);
            expr_type = tmp;
        else
            emit(SUB);
            expr_type = tmp;
        end
    elseif token == Mul
        match(Mul);
        emit(PUSH); expression(Inc); emit(MUL);
        expr_type = tmp;
    elseif token == Div
        match(Div);
        emit(PUSH); expression(Inc); emit(DIV);
        expr_type = tmp;
    elseif token == Mod
        match(Mod);
        emit(PUSH); expression(Inc); emit(MOD);
        expr_type = tmp;
    elseif token == Inc || token == Dec   % postfix
        if text(ti+1) == LI
            text(ti+1) = PUSH;
            emit(LI);
        elseif text(ti+1) == LC
            text(ti+1) = PUSH;
            emit(LC);
        else
            fail(sprintf('%d: bad value in increment', line));
        end
        emit(PUSH);
        emit(IMM);
        emit(pick(expr_type > PTR, 8, 1));
        emit(pick(token == Inc, ADD, SUB));
        emit(pick(expr_type == CHAR, SC, SI));
        emit(PUSH);                 % restore the old value into ax
        emit(IMM);
        emit(pick(expr_type > PTR, 8, 1));
        emit(pick(token == Inc, SUB, ADD));
        match(token);
    elseif token == Brak
        match(Brak);
        emit(PUSH);
        expression(Assign);
        match(93);                  % ']'
        if tmp > PTR || numel(sav_stride) > 1
            % scale the index by the pointer/array stride
            if ~isempty(sav_stride)
                stride = sav_stride(1);
            else
                stride = 8;
            end
            emit(PUSH);
            emit(IMM);
            emit(stride);
            emit(MUL);
        elseif tmp < PTR
            fail(sprintf('%d: pointer type expected', line));
        end
        emit(ADD);                  % ax = base + index*stride
        if numel(sav_stride) > 1
            % multi-dim: a[i] is still an array — keep the address (no load)
            bstrides = sav_stride(2:end);
            expr_type = tmp;
        else
            % scalar element: load
            bstrides = [];
            expr_type = tmp - PTR;
            emit(pick(expr_type == CHAR, LC, LI));
        end
    else
        fail(sprintf('%d: compiler error, token = %d', line, token));
    end
end
end

function statement()
% statement — port of xc.c statement(): if/else, while, block, return, ';',
% or an expression statement.
global token text ti line

% tokens
If=137; Else=135; While=141; Return=139; Assign=142;
% opcodes
JZ=4; JMP=2; LEV=8;

if token == If
    match(If);
    match(40);                      % '('
    expression(Assign);
    match(41);                      % ')'
    emit(JZ);
    b = slot_after();
    statement();
    if token == Else
        match(Else);
        text(b+1) = ti + 3;         % JZ lands past the JMP below
        emit(JMP);
        b = slot_after();
        statement();
    end
    text(b+1) = ti + 1;
elseif token == While
    match(While);
    a = ti + 1;                     % loop head
    match(40);
    expression(Assign);
    match(41);
    emit(JZ);
    b = slot_after();
    statement();
    emit(JMP);
    emit(a);
    text(b+1) = ti + 1;
elseif token == 123                 % '{'
    match(123);
    while token ~= 125              % '}'
        statement();
    end
    match(125);
elseif token == Return
    match(Return);
    if token ~= 59                  % ';'
        expression(Assign);
    end
    match(59);
    emit(LEV);
elseif token == 59                  % ';'
    match(59);
else
    expression(Assign);
    match(59);
end
end

function enum_declaration()
% enum_declaration — port of xc.c: parse { a = 1, b = 3, ... } and mark each
% identifier as an enum constant (Class=Num, Value = the value).
global token token_val line current_id symbols

% tokens
Num=128; Id=133; Assign=142;
INT=1;

i = 0;
while token ~= 125                  % '}'
    if token ~= Id
        fail(sprintf('%d: bad enum identifier %d', line, token));
    end
    next();
    if token == Assign
        next();
        if token ~= Num
            fail(sprintf('%d: bad enum initializer', line));
        end
        i = token_val;
        next();
    end
    symbols(current_id,5) = int64(Num);    % Class = Num
    symbols(current_id,4) = int64(INT);    % Type = INT
    symbols(current_id,6) = int64(i);
    i = i + 1;
    if token == 44                  % ','
        next();
    end
end
end

function function_parameter()
% function_parameter — port of xc.c: parse (int a, char *b, ...) and store
% each parameter as a Loc with Value = its frame slot index. Post-parity:
% (void) declares zero parameters; array parameters (int a[3], char s[])
% decay to pointers. `)` is left for the caller (function_declaration).
global token line current_id symbols index_of_bp

% tokens
Int=138; Char=134; Mul=159; Id=133; Void=165; Num=128;
CHAR=0; INT=1; PTR=2;
Loc=132;

params = 0;
if token == Void                  % (void): zero parameters
    match(Void);
    index_of_bp = params + 1;
    return;
end
while token ~= 41                   % ')'
    type = INT;
    if token == Int
        match(Int);
    elseif token == Char
        type = CHAR;
        match(Char);
    end
    while token == Mul
        match(Mul);
        type = type + PTR;
    end
    if token ~= Id
        fail(sprintf('%d: bad parameter declaration', line));
    end
    if symbols(current_id,5) == Loc
        fail(sprintf('%d: duplicate parameter declaration', line));
    end
    match(Id);
    if token == 164               % '[': array parameter decays to a pointer
        while token == 164
            match(164);
            if token == Num
                match(Num);
            end
            match(93);            % ']'
        end
        type = type + PTR;
    end
    symbols(current_id,8) = symbols(current_id,5);   % BClass
    symbols(current_id,5) = int64(Loc);              % Class = Loc
    symbols(current_id,7) = symbols(current_id,4);   % BType
    symbols(current_id,4) = int64(type);
    symbols(current_id,9) = symbols(current_id,6);   % BValue
    symbols(current_id,6) = int64(params);           % Value = param index
    params = params + 1;
    if token == 44                  % ','
        match(44);
    end
end
index_of_bp = params + 1;
end

function function_body()
% function_body — port of xc.c: local declarations, ENT for the frame,
% statements, trailing LEV.
%
% ENT is emitted FIRST with a placeholder frame size, backpatched after all
% locals are counted. Initializers emit inline right after ENT — the frame
% exists at runtime, so scalar initializers may be any expression
% (non-constant initializers, post-parity).
global token token_val line current_id symbols index_of_bp text ti array_strides

% tokens
Int=138; Char=134; Mul=159; Id=133; Num=128; Assign=142;
CHAR=0; INT=1; PTR=2;
Loc=132;
ENT=6; LEV=8;
LEA=0; IMM=1; PUSH=13; SI=11; SC=12; ADD=25;

pos_local = index_of_bp;

% frame first: ENT with a placeholder size, backpatched below
emit(ENT);
emit(0);
ent_slot = ti;      % slot holding the size operand (0-based)

while token == Int || token == Char
    if token == Int
        basetype = INT;
        match(Int);
    else
        basetype = CHAR;
        match(Char);
    end
    while token ~= 59               % ';'
        type = basetype;
        while token == Mul
            match(Mul);
            type = type + PTR;
        end
        if token ~= Id
            fail(sprintf('%d: bad local declaration', line));
        end
        if symbols(current_id,5) == Loc
            fail(sprintf('%d: duplicate local declaration', line));
        end
        match(Id);
        if token == 164             % '[': local array (post-parity, multi-dim)
            dims = [];
            while token == 164
                match(164);
                if token ~= Num
                    fail(sprintf('%d: bad array size', line));
                end
                d = double(token_val);
                match(Num);
                match(93);          % ']'
                if d < 0
                    fail('bad array size');
                end
                dims = [dims, d];
            end
            elem = pick(type == 0, 1, 8);
            nelem = prod(dims);
            total = elem * nelem;
            slots = ceil(total / 8);
            isarr = 1;
        else
            dims = [];
            elem = pick(type == 0, 1, 8);
            nelem = 1;
            total = 0;
            slots = 1;
            isarr = 0;
        end
        symbols(current_id,8) = symbols(current_id,5);   % BClass
        symbols(current_id,5) = int64(Loc);
        symbols(current_id,7) = symbols(current_id,4);   % BType
        symbols(current_id,4) = int64(pick(isarr, type + 4096, type));
        symbols(current_id,9) = symbols(current_id,6);   % BValue
        pos_local = pos_local + slots;
        symbols(current_id,6) = int64(pos_local);
        symbols(current_id,10) = int64(total);   % sizeof storage
        if isarr
            array_strides{current_id} = array_strides_of(dims, elem);
        end
        if token == 142             % '=': initializer (post-parity)
            if isarr
                % array initializer: constant elements only (nested-brace
                % groups fill sub-arrays per C 6.7.9 brace elision)
                match(142);
                if token == 123     % '{': braces form
                    match(123);
                    vals = parse_braces(dims, 1);
                    match(125);
                elseif token == 34 && type == CHAR  % '=' "str": copy bytes
                    saddr = token_val;
                    next();
                    s = mem_str(saddr);
                    if numel(s) + 1 > nelem
                        fail(sprintf('%d: string initializer too long for array', line));
                    end
                    vals = double(s);
                else
                    fail(sprintf('%d: bad array initializer', line));
                end
                % C zero-initializes the remaining elements: pad with 0s so
                % reused (garbage) frame memory cannot leak into the array
                if numel(vals) < nelem
                    vals = [vals, zeros(1, nelem - numel(vals))];
                end
                for i = 1:numel(vals)
                    if elem == 1
                        % char: byte at base + (i-1)
                        emit(LEA);
                        emit(index_of_bp - pos_local);
                        emit(PUSH);
                        emit(IMM);
                        emit(i - 1);
                        emit(ADD);
                        emit(PUSH);
                        emit(IMM);
                        emit(vals(i));
                        emit(SC);
                    else
                        emit(LEA);       % slot units: base + (i-1)
                        emit(index_of_bp - pos_local + (i - 1));
                        emit(PUSH);
                        emit(IMM);
                        emit(vals(i));
                        emit(SI);
                    end
                end
            else
                % scalar initializer: a constant or any runtime expression
                match(142);
                emit(LEA);
                emit(index_of_bp - pos_local);
                emit(PUSH);
                expression(Assign);
                emit(pick(type == 0, SC, SI));
            end
        end
        if token == 44              % ','
            match(44);
        end
    end
    match(59);                      % ';'
end

% backpatch the ENT frame size now that all locals are counted
text(ent_slot + 1) = int64(pos_local - index_of_bp);

while token ~= 125                  % '}'
    statement();
end

emit(LEV);
end

function function_declaration()
% function_declaration — port of xc.c: (params) { body }, then unwind the
% local symbol entries (restore B fields).
global token current_id symbols

% tokens
Loc=132;

match(40);                          % '('
function_parameter();
match(41);                          % ')'
match(123);                         % '{'
function_body();

% unwind local variable declarations
k = 1;
while k <= size(symbols,1) && symbols(k,1) ~= 0
    if symbols(k,5) == Loc
        symbols(k,5) = symbols(k,8);   % Class  = BClass
        symbols(k,4) = symbols(k,7);   % Type   = BType
        symbols(k,6) = symbols(k,9);   % Value  = BValue
    end
    k = k + 1;
end
end

function global_declaration()
% global_declaration — port of xc.c: enum / type / comma-separated global
% variables or function declarations.
global token line current_id symbols data ti mem token_val array_strides si ginit ginit_n

% tokens
Enum=136; Int=138; Char=134; Mul=159; Id=133; Num=128;
Fun=129; Glo=131;
CHAR=0; INT=1; PTR=2;

basetype = INT;
isvoid = 0;

% enum is treated alone
if token == Enum
    match(Enum);
    if token ~= 123                 % '{'
        match(Id);                  % skip the enum tag
    end
    if token == 123
        match(123);
        enum_declaration();
        match(125);                 % '}'
    end
    match(59);                      % ';'
    return;
end

if token == Int
    match(Int);
elseif token == Char
    match(Char);
    basetype = CHAR;
elseif token == 165                 % Void (post-parity)
    match(165);
    basetype = INT;                 % function return type; calls discard it
    isvoid = 1;
end

while token ~= 59 && token ~= 125   % ';' '}'
    type = basetype;
    while token == Mul
        match(Mul);
        type = type + PTR;
    end
    if token ~= Id
        fail(sprintf('%d: bad global declaration', line));
    end
    if symbols(current_id,5) ~= 0
        fail(sprintf('%d: duplicate global declaration', line));
    end
    match(Id);
    symbols(current_id,4) = int64(type);
    if isvoid && token ~= 40
        fail(sprintf('%d: void variable not supported', line));
    end
    if token == 40                  % '(': function
        symbols(current_id,5) = int64(Fun);
        symbols(current_id,6) = int64(ti + 1);   % 0-based slot of the body
        function_declaration();
    elseif token == 164             % '[': array (post-parity, multi-dim)
        dims = [];
        while token == 164
            match(164);
            if token ~= Num
                fail(sprintf('%d: bad array size', line));
            end
            d = double(token_val);
            match(Num);
            match(93);              % ']'
            if d < 0
                fail('bad array size');
            end
            dims = [dims, d];
        end
        elem = pick(type == 0, 1, 8);           % CHAR -> 1 byte, else 8
        nelem = prod(dims);
        total = elem * nelem;
        symbols(current_id,4) = int64(type + 4096);  % ARRAY_FLAG marker
        symbols(current_id,5) = int64(Glo);
        symbols(current_id,6) = int64(data);     % byte address
        symbols(current_id,10) = int64(total);   % sizeof storage
        array_strides{current_id} = array_strides_of(dims, elem);
        data = data + total;
        base = data - total;   % byte address of a[0]; capture before
                               % the initializer lexes (strings advance data)
        if token == 142             % '=': array initializer (post-parity)
            match(142);
            if token == 123         % '{': braces form (nested-brace ok)
                match(123);
                vals = parse_braces(dims, 1);
                match(125);
                for i = 1:numel(vals)
                    if type == CHAR
                        mem(base + i) = uint8(vals(i));   % byte base + (i-1)
                    else
                        word_store(base + 8*(i-1), vals(i));
                    end
                end
            elseif token == 34 && type == CHAR  % '=' "str": copy bytes
                saddr = token_val;
                next();
                s = mem_str(saddr);
                if numel(s) + 1 > nelem
                    fail(sprintf('%d: string initializer too long for array', line));
                end
                mem(base + 1 : base + numel(s)) = uint8(s);  % NUL padding stays zero
            else
                fail(sprintf('%d: bad array initializer', line));
            end
        end
    else
        symbols(current_id,5) = int64(Glo);
        symbols(current_id,6) = int64(data);     % byte address
        if token == 142             % '=': initializer (post-parity)
            init_pos = si;          % right after '=', start of the initializer
            match(142);
            nonconst = (token == Id && symbols(current_id,5) ~= 128) || ...
                       token == 40 || token == 148 || token == 159 || ...
                       token == 33 || token == 126 || token == 162 || token == 163;
            if nonconst
                % runtime expression: balanced-skip it (no emission) and
                % record {address, source pos, is_char} for the startup
                % prologue, which re-parses it before main runs
                depth = 0;
                while true
                    if (token == 44 || token == 59) && depth == 0
                        break;
                    end
                    if token == 40 || token == 91 || token == 123
                        depth = depth + 1;
                    elseif token == 41 || token == 93 || token == 125
                        depth = depth - 1;
                    end
                    next();
                end
                ginit_n = ginit_n + 1;
                if ginit_n > numel(ginit)
                    fail('too many global initializers');
                end
                ginit{ginit_n} = {data, init_pos, pick(type == CHAR, 1, 0)};
            else
                word_store(data, const_expr());
            end
        end
        data = data + 8;
    end
    if token == 44                  % ','
        match(44);
    end
end
next();
end

function program()
% program — port of xc.c: lex the first token, parse declarations to EOF.
global token
next();
while token > 0
    global_declaration();
end
end

% ---------------------------------------------------------------------------
% Phase 6: syscalls (port of xc.c eval's OPEN/READ/CLOS/PRTF/MALC/MSET/MCMP)
% ---------------------------------------------------------------------------

function s = mem_str(addr)
% mem_str — read a NUL-terminated byte string from mem at 0-based addr.
global mem
s = '';
k = 0;
while true
    if addr + k + 1 > numel(mem)
        fail(sprintf('mem_str: unterminated string at %d', addr));
    end
    b = mem(addr + k + 1);
    if b == 0
        break;
    end
    s = [s, char(b)];
    k = k + 1;
end
end

function ax = sys_open(paddr, flags)
% OPEN — fopen the NUL-terminated path at paddr; flags: 0=O_RDONLY,
% 1=O_WRONLY, 2=O_RDWR. Returns a small int fd into the registry.
global fidv
path = mem_str(paddr);
if flags == 1
    mode = 'w';
elseif flags == 2
    mode = 'r+';
else
    mode = 'r';
end
fid = fopen(path, mode);
if fid < 0
    ax = -1;
else
    slot = find(fidv == -1, 1);   % reuse a freed fd slot (C3)
    if ~isempty(slot)
        fidv(slot) = fid;
        ax = slot - 1;            % 0-based fd
    else
        if numel(fidv) >= 16
            fail('OPEN: too many open files (max 16)');
        end
        fidv = [fidv, fid];
        ax = numel(fidv) - 1;     % 0-based fd
    end
end
end

function ax = sys_read(fd, baddr, cnt)
% READ — read up to cnt bytes from fd into mem at baddr; returns bytes read.
% fread(fid, n) stops at EOF and advances the file position (BUG-18 fixed
% in v1.2.50), so multi-read works directly — no content cache needed.
global fidv mem
if fd < 0 || fd >= numel(fidv) || fidv(fd + 1) < 0   % <0: freed slot (C3)
    ax = -1;
    return;
end
raw = fread(fidv(fd + 1), cnt, 'uint8');
n = numel(raw);
if n > 0
    mem(baddr + 1 : baddr + n) = uint8(raw);
end
ax = n;
end

function ax = sys_close(fd)
% CLOS — fclose by registry fd.
global fidv
if fd < 0 || fd >= numel(fidv) || fidv(fd + 1) < 0   % <0: freed slot (C3)
    ax = -1;
    return;
end
fclose(fidv(fd + 1));
fidv(fd + 1) = -1;   % mark the slot free for reuse
ax = 0;
end

function ax = sys_prtf(tmp, nargs)
% PRTF — read the NUL-terminated format string from mem, strip length
% modifiers so sprintf gets plain %d/%u/%s/%c specs, resolve each
% conversion's arg (%s args are addresses of mem strings; others are
% numeric), sprintf + fprintf with the resolved args passed individually.
% Returns the number of characters printed.
global mem
fmt_addr = word_load(tmp - 8);
fmt = mem_str(fmt_addr);
% Normalize: drop length modifiers (l, ll, h, hh, j, z, t, L) before the
% conversion char — %lld/%llu/%ld/%lu/%hd/%ls etc. become %d/%u/%d/%u/%d/%s
% so sprintf accepts them and %s args resolve as strings.
fmt2 = '';
i = 1;
nf = numel(fmt);
while i <= nf
    if fmt(i) ~= 37          % '%'
        fmt2 = [fmt2, fmt(i)];
        i = i + 1;
        continue;
    end
    j = i + 1;
    if j <= nf && fmt(j) == 37
        fmt2 = [fmt2, '%%'];   % literal percent: no arg
        i = j + 1;
        continue;
    end
    k = j;
    p = j;
    while p <= nf   % flags, width, precision (non-alpha)
        c = double(fmt(p));
        if ~((c >= 65 && c <= 90) || (c >= 97 && c <= 122))
            p = p + 1;
        else
            break;
        end
    end
    k = p;
    while k <= nf   % length modifiers (alpha but not the conversion)
        if ~isempty(strfind('hljztL', fmt(k)))
            k = k + 1;
        else
            break;
        end
    end
    if k > nf
        fail('PRTF: malformed format spec');
    end
    fmt2 = [fmt2, fmt(i), fmt(j:p-1), fmt(k)];
    i = k + 1;
end
nvals = nargs - 1;
if nvals < 0
    fail('PRTF: bad frame');
end
args = zeros(1, nvals);
for k = 1:nvals
    args(k) = double(word_load(tmp - 8*(k+1)));
end
% Build the output spec by spec. Each numeric spec is formatted with a
% single-spec sprintf (safe for numeric args; sprintf with string args
% repeats the format — BUG-16 — so %s is formatted manually). %n writes
% the running count to its arg address; %p prints hex.
out = '';
ai = 1;
i = 1;
nf = numel(fmt2);
while i <= nf
    if fmt2(i) ~= 37          % '%'
        out = [out, fmt2(i)];
        i = i + 1;
        continue;
    end
    j = i + 1;
    if j <= nf && fmt2(j) == 37
        out = [out, '%'];     % literal percent: no arg
        i = j + 1;
        continue;
    end
    while j <= nf             % flags, width, precision (non-alpha)
        c = double(fmt2(j));
        if ~((c >= 65 && c <= 90) || (c >= 97 && c <= 122))
            j = j + 1;
        else
            break;
        end
    end
    if j > nf
        fail('PRTF: malformed format spec');
    end
    if ai > nvals
        fail('PRTF: more format specs than args');
    end
    conv = fmt2(j);
    spec = fmt2(i:j);
    if conv == 115            % 's': the arg addresses a mem string
        out = [out, fmt_str_spec(spec, mem_str(args(ai)))];
    elseif conv == 110        % 'n': write the running count to the arg
        word_store(args(ai), numel(out));
    elseif conv == 112        % 'p': pointer as lowercase hex
        out = [out, hex_addr(args(ai))];
    else
        out = [out, sprintf(spec, args(ai))];
    end
    ai = ai + 1;
    i = j + 1;
end
fprintf('%s', out);
ax = numel(out);
end

function s = fmt_str_spec(spec, str)
% fmt_str_spec — %s width/precision/flags applied manually (the clone's
% sprintf repeats the format for string args — BUG-16 — so width/precision
% are implemented here).
rest = spec(2:end-1);   % between '%' and 's'
left = 0;
k = 1;
while k <= numel(rest) && ...
      (rest(k) == '-' || rest(k) == '+' || rest(k) == '0' || rest(k) == '#')
    if rest(k) == '-'
        left = 1;
    end
    k = k + 1;
end
w = 0;
while k <= numel(rest) && rest(k) >= '0' && rest(k) <= '9'
    w = w * 10 + (double(rest(k)) - 48);
    k = k + 1;
end
prec = -1;
if k <= numel(rest) && rest(k) == '.'
    k = k + 1;
    prec = 0;
    while k <= numel(rest) && rest(k) >= '0' && rest(k) <= '9'
        prec = prec * 10 + (double(rest(k)) - 48);
        k = k + 1;
    end
end
if prec >= 0 && numel(str) > prec
    str = str(1:prec);
end
if numel(str) < w
    % repmat(' ',1,n) returns a double on the runtime — build the pad as
    % char(32*ones) so the concatenation stays char
    pad = char(32 * ones(1, w - numel(str)));
    if left
        s = [str, pad];
    else
        s = [pad, str];
    end
else
    s = str;
end
end

function s = hex_addr(v)
% hex_addr — %p formatting: lowercase hex with a 0x prefix.
s = ['0x', lower(dec2hex(v))];
end

function ax = sys_malc(n)
% MALC — bump allocator: return the old heap pointer, advance by n bytes.
% The heap lives in [data, 2*poolsize); hp starts at data after compile.
global hp poolsize
if n < 0 || hp + n > 2*poolsize
    fail(sprintf('MALC: out of heap (hp=%d n=%d)', hp, n));
end
ax = hp;
hp = hp + n;
end

function ax = sys_mset(daddr, val, cnt)
% MSET — memset(dest, val, count): fill count bytes with val's low byte.
global mem
if daddr + cnt > numel(mem)
    fail('MSET: out of range');
end
mem(daddr+1 : daddr+cnt) = uint8(mod(int64(val), int64(256)));
ax = daddr;
end

function ax = sys_mcmp(s1, s2, cnt)
% MCMP — memcmp(s1, s2, count) -> -1/0/1 on the first differing byte.
global mem
for k = 0:cnt-1
    b1 = mem(s1 + k + 1);
    b2 = mem(s2 + k + 1);
    if b1 ~= b2
        ax = sign(double(b1) - double(b2));
        return;
    end
end
ax = 0;
end
