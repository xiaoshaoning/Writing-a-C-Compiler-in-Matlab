/* cc34_aggrinit.c - local struct aggregate initializers: positional,
 * nested braces, designated `.name = v`, and C's zero-fill for the members
 * not named. Exit 96. */
#include <stdio.h>
struct P { int x; int y; };
struct S { int a; struct P p; int z; };
int main() {
    struct S s = {1, {2, 3}, 4};
    struct S d = {.z = 7, .a = 5};          /* p zero-filled */
    struct S q = {9};                       /* the rest zero-filled */
    if (s.a != 1 || s.p.x != 2 || s.p.y != 3 || s.z != 4) { return 1; }
    if (d.a != 5 || d.p.x != 0 || d.p.y != 0 || d.z != 7) { return 2; }
    if (q.a != 9 || q.p.x != 0 || q.p.y != 0 || q.z != 0) { return 3; }
    printf("%d %d %d\n", s.a + d.a + q.a, s.p.x + s.p.y, s.z + d.z + q.z);
    return 96;
}
