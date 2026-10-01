/* cc30_typedef.c - typedef of struct, union, pointer and array types, at
 * file scope and local, as globals and as locals. Exit 96. */
#include <stdio.h>
typedef struct { int x; int y; } P;
typedef union { int i; char c; } U;
typedef int *ip;
typedef int ia[2];
P gp;
ia ga;
int main() {
    P p;
    p.x = 3;
    p.y = 4;
    U u;
    u.i = 65;
    if (u.c != 65) { return 1; }
    int v = 9;
    ip q;
    q = &v;
    if (*q != 9) { return 2; }
    ia a;
    a[1] = 7;
    if (a[1] != 7) { return 3; }
    if (sizeof(ia) != 2 * sizeof(int)) { return 4; }
    gp.x = 1;
    ga[0] = 2;
    if (gp.x + ga[0] != 3) { return 5; }
    if (sizeof(ip) != sizeof(int *)) { return 6; }
    printf("%d %d %d\n", p.x + p.y, u.c, a[1]);
    return 96;
}
