/* cc46_aggrinit2.c - the three shapes that made the two initializer parsers
 * diverge: a nested struct designated and then ANOTHER designator, a
 * positional array member followed by a member, and an array of struct values
 * followed by a member. Each at file scope and local, because they share one
 * parser now. Exit 96. */
#include <stdio.h>
struct P { int x; int y; };
struct S { int a; struct P p; int z; };
struct A { int v[3]; int n; };
struct B { struct P v[2]; int n; };
struct S g1 = {.p = {2, 3}, .a = 5};        /* {5,{2,3},0} */
struct A g2 = {1, 2, 3, 4};                 /* v={1,2,3}, n=4 */
struct B g3 = {{{1, 2}, {3, 4}}, 5};        /* v={{1,2},{3,4}}, n=5 */
int main() {
    struct S l1 = {.p = {2, 3}, .a = 5};
    struct A l2 = {1, 2, 3, 4};
    struct B l3 = {{{1, 2}, {3, 4}}, 5};
    if (g1.a != 5 || g1.p.x != 2 || g1.p.y != 3 || g1.z != 0) { return 1; }
    if (g2.v[0] != 1 || g2.v[2] != 3 || g2.n != 4) { return 2; }
    if (g3.v[0].x != 1 || g3.v[1].y != 4 || g3.n != 5) { return 3; }
    if (l1.a != 5 || l1.p.x != 2 || l1.p.y != 3 || l1.z != 0) { return 4; }
    if (l2.v[0] != 1 || l2.v[2] != 3 || l2.n != 4) { return 5; }
    if (l3.v[0].x != 1 || l3.v[1].y != 4 || l3.n != 5) { return 6; }
    printf("%d %d %d %d\n", g1.a + g1.p.y, g2.v[2] + g2.n, g3.v[0].x + g3.n, l3.v[1].x);
    return 96;
}
