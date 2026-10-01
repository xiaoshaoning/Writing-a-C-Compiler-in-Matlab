/* cc27_int.c - `int` is 32-bit like C: sizeof, wrap on store, and the
 * int-pointer stride. Compiler track only (the interpreter has no
 * long/pointer dialect here). Exit 96. */
#include <stdio.h>
int main() {
    int y = 2147483647;
    y = y + 1;                        /* 32-bit wrap: -2147483648 */
    int a[3];
    int *p;
    a[0] = 1;
    a[1] = 2;
    p = &a[0];
    p++;                              /* 4-byte stride, not 8 */
    if (sizeof(int) != 4) { return 1; }
    if (y != -2147483648) { return 2; }
    if (*p != 2) { return 3; }
    if (sizeof(int*) != 8) { return 4; }
    if (sizeof(short) != 2) { return 5; }
    printf("%d %d %d\n", (int) sizeof(int), y, *p);
    return 96;
}
