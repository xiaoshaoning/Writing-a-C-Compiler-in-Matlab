/* cc40_elision.c - C's brace elision (6.7.9p20): an aggregate member's
 * braces may be left out, so `{1, 2, 3, 4}` fills a nested struct flat, and
 * an explicit group is still accepted. Exit 96. */
#include <stdio.h>
struct P { int x; int y; };
struct Q { struct P a; struct P b; };
struct S { int v[3]; struct P p; int n; };
int main() {
    struct Q q = {1, 2, 3, 4};           /* q.a = {1,2}, q.b = {3,4} */
    struct S s = {5, 6, 7, {8, 9}, 10};  /* flat array, braced struct */
    struct Q r = {{1, 2}, {3, 4}};       /* braces still allowed */
    if (q.a.x != 1 || q.a.y != 2 || q.b.x != 3 || q.b.y != 4) { return 1; }
    if (s.v[0] != 5 || s.v[2] != 7 || s.p.x != 8 || s.p.y != 9) { return 2; }
    if (s.n != 10) { return 3; }
    if (r.a.x != 1 || r.b.y != 4) { return 4; }
    printf("%d %d %d %d\n", q.a.x + q.b.y, s.v[2] + s.p.y, r.b.x, r.a.y + r.b.x);
    return 96;
}
