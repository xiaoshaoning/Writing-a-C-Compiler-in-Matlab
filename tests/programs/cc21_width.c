/* cc21_width.c - narrow integer widths in the compiler track: local
 * short/long declarations, 16-bit truncation on store and on cast, and
 * sizeof of the narrow types. The interpreter has no short/long, so this
 * is compiler-track only. Exit 173. */
short gs = 300;
int main() {
    short s = 3;
    short t = 70000;            /* 16-bit store truncation: 4464 */
    short c = (short) 0x10003;  /* 16-bit cast truncation: 3 */
    short z = (short) 3.9;      /* double -> short: 3 */
    long l = 5;
    int a = sizeof(short);      /* 2 */
    int b = sizeof(char);       /* 1 */
    if (t != 4464) { return 1; }
    if (c != 3) { return 2; }
    if (z != 3) { return 3; }
    if (a != 2) { return 4; }
    if (b != 1) { return 5; }
    if (gs != 300) { return 6; }
    if (l != 5) { return 7; }
    return (s + t + c + z + a + b + gs + l) % 256;   /* 4781 -> 173 */
}
