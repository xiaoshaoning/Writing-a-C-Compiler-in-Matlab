/* cc23_suffix.c - C integer constant suffixes: u/U and l/L, singly and
 * combined (ul, llu). The value is unchanged; the suffix only has to lex,
 * so this runs on both tracks. Exit 72. */
int gu = 40u;
int main() {
    int a = 5u;
    int b = 0xFFu;      /* hex 255 */
    int c = 10L;
    int d = 7UL;
    int e = 3llu;
    int f = 010u;       /* octal 8 */
    if (a != 5) { return 1; }
    if (b != 255) { return 2; }
    if (c != 10) { return 3; }
    if (d != 7) { return 4; }
    if (e != 3) { return 5; }
    if (f != 8) { return 6; }
    if (gu != 40) { return 7; }
    return (a + b + c + d + e + f + gu) % 256;   /* 328 -> 72 */
}
