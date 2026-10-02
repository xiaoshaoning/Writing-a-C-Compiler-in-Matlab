/* cc41_mdim.c - multi-dimensional array members: the stride table has to
 * cover every dimension, so `s.m[i][j]` walks rows, and the initializer
 * takes either nested or flat groups. Exit 96. */
#include <stdio.h>
struct S { int m[2][3]; int n; };
struct C { char c[2][4]; int n; };
int main() {
    struct S s;
    struct S b = {{{1, 2, 3}, {4, 5, 6}}};
    struct S f = {{1, 2, 3, 4, 5, 6}};
    struct C k = {{{'a', 'b', 'c', 0}, {'x', 'y', 0, 0}}, 9};
    s.m[0][0] = 1; s.m[0][2] = 3; s.m[1][0] = 4; s.m[1][2] = 6; s.n = 7;
    if (s.m[0][0] + s.m[0][2] + s.m[1][0] + s.m[1][2] + s.n != 21) { return 1; }
    if (b.m[0][1] != 2 || b.m[1][2] != 6) { return 2; }
    if (f.m[1][0] != 4 || f.m[0][2] != 3) { return 3; }
    if (sizeof(s.m) != 6 * sizeof(int)) { return 4; }
    if (k.c[0][2] != 'c' || k.c[1][1] != 'y' || k.n != 9) { return 5; }
    printf("%d %d %d %d\n", s.m[1][2] + s.n, b.m[0][0] + b.m[1][2], f.m[1][0], k.c[1][0]);
    return 96;
}
