/* cc43_gdesig.c - designated initializers at FILE scope, and array members
 * in a global struct initializer. Both need the flattened leaf values placed
 * at their own offset: a skipped member must be zero-filled, and a member
 * named twice is overwritten. Exit 96. */
#include <stdio.h>
struct P { int x; int y; };
struct S { int a; struct P p; int z; };
struct A { int v[3]; int n; };
struct S g = {.z = 7, .a = 1};              /* p zero-filled */
struct S h = {.p = {2, 3}, .a = 5};
struct S w = {.z = 9, .p = {4, 5}, .a = 6}; /* a designator after another */
struct A r = {.n = 4, .v = {1, 2, 3}};      /* an array member designated */
int main() {
    if (g.a != 1 || g.p.x != 0 || g.p.y != 0 || g.z != 7) { return 1; }
    if (h.a != 5 || h.p.x != 2 || h.p.y != 3 || h.z != 0) { return 2; }
    if (w.a != 6 || w.p.x != 4 || w.p.y != 5 || w.z != 9) { return 3; }
    if (r.v[0] != 1 || r.v[1] != 2 || r.v[2] != 3 || r.n != 4) { return 4; }
    printf("%d %d %d %d\n", g.a + g.z, h.a + h.p.y, w.p.x + w.z, r.v[2] + r.n);
    return 96;
}
