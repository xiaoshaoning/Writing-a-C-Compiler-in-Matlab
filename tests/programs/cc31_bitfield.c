/* cc31_bitfield.c - bit-fields: a read returns only the field's bits, sign-
 * or zero-extended per the declared type, and the value is confined to the
 * width. Each field owns a whole slot here, so only the values are compared
 * (the consumers's struct layout is 8-byte coarse anyway). Exit 96. */
#include <stdio.h>
struct S { unsigned int a : 3; int b : 5; unsigned int c : 1; };
int main() {
    struct S s;
    s.a = 9;                    /* 3 bits -> 1 */
    s.b = 15;                   /* fits the 5-bit signed range */
    s.c = 2;                    /* 1 bit -> 0 */
    if (s.a != 1) { return 1; }
    if (s.b != 15) { return 2; }
    if (s.c != 0) { return 3; }
    s.b = -16;                  /* the 5-bit signed minimum */
    if (s.b != -16) { return 4; }
    s.a = -1;
    if (s.a != 7) { return 5; }
    s.c = 1;
    if (s.c != 1) { return 6; }
    printf("%u %d %u\n", s.a, s.b, s.c);
    return 96;
}
