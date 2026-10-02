/* cc38_funptr.c - calls through function pointers with by-value struct
 * arguments: every pushed word has to be counted (the pointer is found
 * relative to rsp) and the copy keeps its field order. Exit 96. */
#include <stdio.h>
struct S { int a; int b; int c; };
struct P { int x; int y; };
int three(struct S s) { return s.a * 100 + s.b * 10 + s.c; }
int two(struct P p, int k) { return p.x * 100 + p.y * 10 + k; }
int add(int a, int b) { return a + b; }
int main() {
    int (*f3)(struct S) = three;
    int (*f2)(struct P, int) = two;
    int (*fa)(int, int) = add;
    struct S s;
    struct P p;
    s.a = 1; s.b = 2; s.c = 3;
    p.x = 4; p.y = 5;
    if (f3(s) != 123) { return 1; }
    if (f2(p, 6) != 456) { return 2; }
    if (fa(3, 4) != 7) { return 3; }
    if (f3(s) + f2(p, 6) + fa(3, 4) != 586) { return 4; }
    printf("%d %d %d\n", f3(s), f2(p, 6), fa(3, 4));
    return 96;
}
