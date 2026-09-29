/* cc26_signed.c - signed/unsigned narrow types widen with the right sign,
 * and the full specifier grammar parses. Compiler track only: the
 * interpreter has no narrow types. Exit 96. */
#include <stdio.h>
int main() {
    short s = -1;
    char c = -1;
    unsigned short us = 65535;
    unsigned char uc = 200;
    signed char sc = -1;
    long long ll = -2;
    int i = s;                  /* sign-extend: -1 */
    int j = c;                  /* sign-extend: -1 */
    int k = us;                 /* zero-extend: 65535 */
    int m = uc;                 /* zero-extend: 200 */
    int n = sc;                 /* -1 */
    int p = ll;                 /* -2 */
    if (i != -1) { return 1; }
    if (j != -1) { return 2; }
    if (k != 65535) { return 3; }
    if (m != 200) { return 4; }
    if (n != -1) { return 5; }
    if (p != -2) { return 6; }
    if (sizeof(short) != 2 || sizeof(unsigned short) != 2) { return 7; }
    if (sizeof(char) != 1 || sizeof(unsigned char) != 1) { return 8; }
    if (sizeof(long long) != 8) { return 9; }
    printf("%d %d %d %d %d %d\n", i, j, k, m, n, p);
    return 96;
}
