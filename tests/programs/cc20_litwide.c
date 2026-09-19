/* cc20_litwide.c - full-width integer literals (compiler track only: the
 * interpreter's ints are 32-bit). Hex and octal both wrap mod 2^64 to the
 * all-ones bit pattern, which is -1 as a signed 64-bit value. Exit 7. */
int gwide = 0xFFFFFFFFFFFFFFFF;
int main() {
    int o = 01777777777777777777777;    /* 2^64 - 1, in octal */
    if (gwide != -1) { return 1; }
    if (o != -1) { return 2; }
    return 7;
}
