/* cc25_fmt.c - 64-bit %u/%x/%X/%o printing is exact, i.e. the full unsigned
 * 64-bit pattern, not a double-rounded value (which lost the low bits above
 * 2^53). Compiler track only: Windows gcc's long is 32-bit, so gcc cannot be
 * the oracle. Exit 96. */
#include <stdio.h>
int main() {
    long b = -1;
    printf("%lx\n", 9223372036854775807L);   /* 7fffffffffffffff */
    printf("%lx\n", b);                      /* ffffffffffffffff */
    printf("%lu\n", b);                      /* 18446744073709551615 */
    printf("%016lx\n", 9007199254740993);    /* 0020000000000001 */
    printf("%lo\n", b);                      /* 1777777777777777777777 */
    printf("%X\n", b);                       /* FFFFFFFFFFFFFFFF */
    return 96;
}
