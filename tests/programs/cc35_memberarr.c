/* cc35_memberarr.c - array members: indexing, decay to a pointer, a nested
 * aggregate initializer, and sizeof of the array itself. Exit 96. */
#include <stdio.h>
#include <string.h>
struct S { char name[8]; int v[3]; int n; };
int main() {
    struct S s = {{0}, {1, 2, 3}, 9};
    int *p;
    strcpy(s.name, "hi");
    if (strlen(s.name) != 2) { return 1; }
    if (s.v[0] != 1 || s.v[2] != 3) { return 2; }
    if (sizeof(s.v) != 12) { return 3; }
    if (sizeof(s.name) != 8) { return 4; }
    p = s.v;
    p[1] = 7;
    if (s.v[1] != 7) { return 5; }
    s.name[0] = 'A';
    if (s.name[0] != 'A') { return 6; }
    if (s.n != 9) { return 7; }
    printf("%s %d %d %d\n", s.name, s.v[0], s.v[1], s.v[2]);
    return 96;
}
