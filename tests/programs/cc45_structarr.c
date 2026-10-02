/* cc45_structarr.c - an array of struct values as a member: it takes its own
 * brace group with one group per element, and the element stride is the
 * struct's size. Local form only (a file-scope one is still wrong - see the
 * commit message). Exit 96. */
#include <stdio.h>
struct P { int x; int y; };
struct S { struct P v[2]; int n; };
int main() {
    struct S s = {{{1, 2}, {3, 4}}, 5};
    struct S t;
    t.v[0].x = 7; t.v[1].y = 8; t.n = 9;
    if (s.v[0].x != 1 || s.v[0].y != 2) { return 1; }
    if (s.v[1].x != 3 || s.v[1].y != 4) { return 2; }
    if (s.n != 5) { return 3; }
    if (t.v[0].x != 7 || t.v[1].y != 8 || t.n != 9) { return 4; }
    printf("%d %d %d %d\n", s.v[0].x + s.v[1].y, s.n, t.v[0].x, t.v[1].y);
    return 96;
}
