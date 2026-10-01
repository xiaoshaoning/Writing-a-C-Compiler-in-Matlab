/* cc29_union.c - unions: every member shares offset 0 and the union is as
 * large as its largest member; anonymous struct/union types work (also as
 * members); struct members may be any scalar type. Exit 96. */
#include <stdio.h>
union U { int i; char c; double d; };
struct S { int a; union U u; };
struct A { int a; union { int i; char c; } u; };
int main() {
    union U u;
    u.i = 0x41424344;                 /* little-endian: the low byte is 0x44 */
    if (u.c != 0x44) { return 1; }
    if (sizeof(union U) != 8) { return 2; }   /* largest member is a double */
    struct S s;
    s.a = 1;
    s.u.i = 2;
    if (s.a + s.u.i != 3) { return 3; }
    struct A an;
    an.a = 4;
    an.u.i = 5;
    if (an.a + an.u.i != 9) { return 4; }
    union { int i; char c; } anon;
    anon.i = 65;
    if (anon.c != 65) { return 5; }
    if (sizeof(union { int i; long long l; }) != 8) { return 6; }
    struct { short s; int i; } sc;
    sc.s = -1;
    sc.i = 2;
    if (sc.s + sc.i != 1) { return 7; }
    printf("%d %d %d\n", u.c, (int) sizeof(union U), an.a + an.u.i);
    return 96;
}
