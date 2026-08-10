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
global symbols symbol_names current_id idmain  % symbol table
global mem data data_top hp stack_base      % memory segments
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
data         = 0;                           % next free data byte (xc.c char *data)
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
old_src   = 0;      % 0-based index of the current source line start
old_text  = 0;      % 0-based slot of the last -s-dumped instruction

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

% ---- seed keywords + syscalls into the symbol table (xc.c main) ----
seed_symbols();
old_src = 0;
old_text = 0;

% ---- Phase 3: parser lands in Phases 3-6 ----
fail('parser pipeline not implemented yet (Phases 3-6)');

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
    elseif op >= 30 && op <= 36   % syscalls — Phase 6
        fail(sprintf('syscall %d not implemented yet (Phase 6)', op));
    else
        fail(sprintf('unknown instruction:%d', op));
    end
end
end

function [q, r] = cdivmod(a, b)
% cdivmod — C truncating division/remainder for int64 operands, exact for
% |a|,|b| < 2^53, b ~= 0. Quotient truncates toward zero; the remainder
% takes the sign of the dividend (xc.c `a / b` / `a % b` semantics).
% (Integer division of typed operands is not portable across MATLAB
% versions, so the VM computes it from exact double math.)
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

fprintf('vm_selftest: %d cases, %d failed\n', 25, nfail);
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
        if assembly
            % -s dump: source line + instructions emitted since last line
            fprintf('%d: %s', line, src(old_src+1 : si));
            old_src = si;
            while old_text < ti
                old_text = old_text + 1;
                fprintf('%8.4s', opname(text(old_text+1)));
                if text(old_text+1) <= 7   % ADJ: ops with an operand slot
                    old_text = old_text + 1;
                    fprintf(' %d\n', text(old_text+1));
                else
                    fprintf('\n');
                end
            end
        end
        line = line + 1;
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
% Value=opcode, 'void' becomes Char, 'main' is recorded as idmain.
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
next();                                  % 'void' -> Token = Char
symbols(current_id, 1) = int64(134);
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
nfail = nfail + lex_case(['"abc" "a' BS 'nb" ' SQ 'x' SQ ' ' SQ BS 'n' SQ ' ' SQ BS BS SQ], ...
    [34 34 Num Num Num], 'strings and char literals', ...
    'vals', [0 3 120 10 92], 'mem', {0, [97 98 99 97 10 98]});

% 6) comments and # skip + line counting
nfail = nfail + lex_case(['int a; // comment' char(10) '#define X 1' char(10) 'int b;'], ...
    [Int Id 59 Int Id 59], 'comments/# skip + line count', ...
    'seeded', 1, 'line', 3);

% 7) identifier insert + hash lookup
nfail = nfail + lex_case('foo foo bar', [Id Id Id], 'identifier lookup');

% 8) -s line dump fires on newline (content asserted via run_tests evalc)
nfail = nfail + lex_case(['int x;' char(10) 'int y;'], [Int Id 59 Int Id 59], ...
    '-s line dump', 'seeded', 1, 'assembly', 1);

fprintf('lex_selftest: %d cases, %d failed\n', 8, nfail);
end

function nf = lex_case(srcstr, expected, name, varargin)
% lex_case — reset the lexer state, optionally seed the symbol table,
% tokenize srcstr, and compare the token stream with `expected`.
% Options (key/value pairs): 'vals' expected token_vals; 'seeded' nonzero
% to run seed_symbols() first; 'assembly' nonzero to enable the -s dump;
% 'line' expected final line counter; 'mem' {addr, bytes} to verify bytes
% stored in the data region.
global src si line token token_val current_id symbols symbol_names ...
       data mem text ti old_src old_text assembly poolsize

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
