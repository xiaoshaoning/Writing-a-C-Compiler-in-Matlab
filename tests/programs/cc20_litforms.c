/* cc20_litforms.c - integer literal forms: decimal, hex and octal, in
 * expressions, a global, an array size and an enum. The 0777 case is the
 * one a decimal-only lexer silently got wrong (0777 & 0xFF = 255; reading
 * 0777 as decimal gives 777 & 0xFF = 9). Exit 104. */
int goct = 010;                 /* octal 8 */
int ghex = 0x1F;                /* hex 31 */
int garr[04];                   /* array size 4 (octal) */
enum { LE = 017 };              /* octal 15 */
int main() {
    int a = 0777 & 0xFF;        /* octal 511 & 255 = 255 */
    int b = 0X2A + 010;         /* hex 42 + octal 8 = 50 */
    int c = 00 + 0 + 0x0;       /* three spellings of zero */
    if (a != 255) { return 1; }
    if (b != 50) { return 2; }
    if (c != 0) { return 3; }
    if (goct + ghex != 39) { return 4; }
    if (LE != 15) { return 5; }
    garr[0] = 1;
    return (a + b + c + goct + ghex + LE + garr[0]) % 256;   /* 360 -> 104 */
}
