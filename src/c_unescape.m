function [val, ni] = c_unescape(code, i)
% c_unescape - decode one C escape sequence from a code vector.
%
%   [val, ni] = c_unescape(code, i)
%
% code is a double code vector; i (1-based) points at the first character
% AFTER the backslash. Returns the byte value of the escape and the index
% just past it. Handles the simple escapes, octal \NNN (1-3 digits) and
% hex \xNN; an unknown escape yields the character itself (as gcc does),
% and a trailing backslash yields -1 so the caller can report an
% unterminated literal. Shared by the xc and cc_int lexers so the table
% lives in one place.
n = numel(code);
if i > n
    val = -1;
    ni = i;
    return;
end
c = code(i);
if c >= '0' && c <= '7'                 % octal: at most three digits
    v = 0;
    k = 0;
    while k < 3 && i <= n && code(i) >= '0' && code(i) <= '7'
        v = v * 8 + (double(code(i)) - 48);
        i = i + 1;
        k = k + 1;
    end
    val = v;
    ni = i;
    return;
end
if c == 'x' || c == 'X'                 % hex: one or more digits
    i = i + 1;
    v = 0;
    nd = 0;
    while i <= n
        d = hexval(code(i));
        if d < 0
            break;
        end
        v = v * 16 + d;
        i = i + 1;
        nd = nd + 1;
    end
    if nd == 0
        val = double('x');              % '\x' with no digits: gcc keeps 'x'
    else
        val = v;
    end
    ni = i;
    return;
end
switch c
    case 'n', val = 10;
    case 't', val = 9;
    case 'r', val = 13;
    case 'a', val = 7;
    case 'b', val = 8;
    case 'f', val = 12;
    case 'v', val = 11;
    case char(92), val = 92;            % '\\'
    case char(39), val = 39;            % '\''
    case char(34), val = 34;            % '\"'
    case char(63), val = 63;            % '\?'
    otherwise, val = double(c);         % gcc: unknown escape keeps the char
end
ni = i + 1;
end

function d = hexval(ch)
d = double(ch);
if d >= 48 && d <= 57
    d = d - 48;
elseif d >= 97 && d <= 102
    d = d - 87;
elseif d >= 65 && d <= 70
    d = d - 55;
else
    d = -1;
end
end
