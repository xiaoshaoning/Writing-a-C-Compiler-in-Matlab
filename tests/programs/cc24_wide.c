/* cc24_wide.c - 64-bit decimal integer literals stay exact above 2^53
 * through emission, the immediate parse, the 64-bit store and %ld.
 * Compiler track only: the interpreter and Windows gcc use 32-bit long,
 * so neither can be the oracle. Exit 96. */
#include <stdio.h>
int main() {
    long a = 9007199254740993;              /* 2^53 + 1 */
    long b = 9223372036854775806;           /* INT64_MAX - 1 */
    long c = -9223372036854775807 - 1;      /* INT64_MIN */
    long d = -9007199254740993;
    if (a - 9007199254740992 != 1) { return 1; }
    if (b - 9223372036854775805 != 1) { return 2; }
    if (c + 9223372036854775807 != -1) { return 3; }
    if (d + 9007199254740993 != 0) { return 4; }
    printf("%ld\n", a);
    printf("%ld\n", b);
    printf("%ld\n", c);
    printf("%ld\n", d);
    return 96;
}
