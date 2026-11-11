/* cc25_fmt.c - 64-bit %u/%x/%X/%o printing is exact, i.e. the full unsigned
 * 64-bit pattern, not a double-rounded value (which lost the low bits above
 * 2^53). The values are long long and the specs say `ll`, so the CRT and this
 * backend both read 64 bits - the guard is gcc-comparable. Exit 96. */
#include <stdio.h>
int main() {
    long long b = -1;
    /* `ll` for the 64-bit values: a plain `l` is a 32-bit long on this target,
       as gcc has it too, so a mismatched spec would silently print the low
       half. With `ll` the CRT and this backend agree, and gcc can be the
       oracle for this guard instead of "compiler track only". */
    printf("%llx\n", 9223372036854775807LL);  /* 7fffffffffffffff */
    printf("%llx\n", b);                      /* ffffffffffffffff */
    printf("%llu\n", b);                      /* 18446744073709551615 */
    printf("%016llx\n", 9007199254740993);    /* 0020000000000001 */
    printf("%llo\n", b);                      /* 1777777777777777777777 */
    printf("%llX\n", b);                      /* FFFFFFFFFFFFFFFF */
    return 96;
}
