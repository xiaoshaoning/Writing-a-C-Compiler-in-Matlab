/* cc32_byval.c - struct-by-value arguments: the copy must keep the field
 * order (the caller pushes the highest address first, so member 0 lands at
 * the lowest stack address). Exit 96. */
#include <stdio.h>
struct S { int a; int b; int c; };
struct P { int x; int y; };
int three(struct S s) { return s.a * 100 + s.b * 10 + s.c; }
int two(struct P p, int k) { return p.x * 100 + p.y * 10 + k; }
int outer(struct S s) { return three(s) + 1; }
int main() {
    struct S s;
    struct P p;
    s.a = 1; s.b = 2; s.c = 3;
    p.x = 4; p.y = 5;
    if (three(s) != 123) { return 1; }
    if (two(p, 6) != 456) { return 2; }
    if (outer(s) != 124) { return 3; }
    printf("%d %d %d\n", three(s), two(p, 6), outer(s));
    return 96;
}
