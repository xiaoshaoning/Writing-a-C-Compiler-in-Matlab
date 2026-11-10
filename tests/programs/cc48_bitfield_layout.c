/* cc48_bitfield_layout.c - bit-fields share a storage unit the way gcc's MS
 * layout does: consecutive fields of the same declared type pack into one unit
 * while they fit, a different type or an overflow starts a new unit, an unnamed
 * `: 0` ends the current unit, and a plain member resumes after the unit's
 * whole size. Every number here was measured from gcc (x86-64 ucrt64) and the
 * values must survive the packing: a store into one field is a masked
 * read-modify-write, so the field beside it keeps its value. Exit 96. */
int printf(const char *, ...);

struct B1 { unsigned int a : 3; unsigned int b : 5; };            /* 4 */
struct B2 { unsigned int a : 3; unsigned int b : 30; };           /* 8, b moves */
struct B3 { unsigned char a : 3; unsigned char b : 5; };          /* 1 */
struct B4 { unsigned int a : 3; unsigned char b : 3; };           /* 8, new type */
struct B5 { unsigned int a : 3; unsigned int : 0; unsigned int b : 3; };
struct B6 { unsigned int a : 4; unsigned int b : 4; int n; };     /* 8, n at 4 */
struct B7 { char c; unsigned int a : 3; };                        /* 8, unit at 4 */
struct B8 { unsigned short a : 9; unsigned short b : 9; };        /* 4 */
struct B9 { int a : 4; int b : 4; int c : 4; int d : 4; };        /* 4 */
struct B15 { unsigned int a : 3; unsigned int : 3; unsigned int b : 3; };
/* the run's key is the declared type's SIZE, not its identity: signedness does
 * not split a unit, a different size does (measured from gcc) */
struct B10 { int a : 3; unsigned int b : 3; };           /* 4, shares */
struct B11 { short a : 3; unsigned short b : 3; };       /* 2, shares */
struct B12 { char a : 3; signed char b : 3; };           /* 1, shares */
struct B13 { int a : 3; short b : 3; };                  /* 8, unit at 4 */
struct B14 { unsigned short a : 9; short b : 9; };       /* 4, b moves */

struct B1 g1; struct B2 g2; struct B3 g3; struct B6 g6; struct B10 g10;
struct B7 g7; struct B8 g8; struct B9 g9; struct B1 arr[3];
struct B1 init1 = {5, 17};          /* a data-section image, one unit */
struct B6 init6 = {3, 9, 77};
struct B9 init9 = {1, 2, 3, 4};

int main() {
    struct B1 l;
    struct B3 m;
    struct B1 copy;

    /* layout, measured from gcc */
    if (sizeof(struct B1) != 4) { return 1; }
    if (sizeof(struct B2) != 8) { return 2; }
    if (sizeof(struct B3) != 1) { return 3; }
    if (sizeof(struct B4) != 8) { return 4; }
    if (sizeof(struct B5) != 8) { return 5; }
    if (sizeof(struct B6) != 8) { return 6; }
    if (sizeof(struct B7) != 8) { return 7; }
    if (sizeof(struct B8) != 4) { return 8; }
    if (sizeof(struct B9) != 4) { return 9; }
    if (sizeof(struct B15) != 4) { return 10; }
    if (sizeof(struct B10) != 4) { return 29; }
    if (sizeof(struct B11) != 2) { return 30; }
    if (sizeof(struct B12) != 1) { return 31; }
    if (sizeof(struct B13) != 8) { return 32; }
    if (sizeof(struct B14) != 4) { return 33; }
    if ((char *)&g6.n - (char *)&g6 != 4) { return 11; }     /* after the unit */
    if ((char *)&g7.c - (char *)&g7 != 0) { return 12; }
    if ((char *)&arr[1] - (char *)&arr[0] != 4) { return 13; }  /* stride */

    /* two fields in one unit, one at a time: the neighbour must survive */
    g1.a = 7; g1.b = 31;
    if (g1.a != 7 || g1.b != 31) { return 14; }
    g1.b = 1;
    if (g1.a != 7 || g1.b != 1) { return 15; }
    m.a = 5; m.b = 17;
    if (m.a != 5 || m.b != 17) { return 16; }
    g3.a = 7; g3.b = 31;
    if (g3.a != 7 || g3.b != 31) { return 17; }

    /* compound, increment, wraparound */
    g9.a = 3; g9.b = 4; g9.c = 5; g9.d = 6;
    g9.a += 2; g9.b -= 1; g9.c++; ++g9.d;
    if (g9.a != 5 || g9.b != 3 || g9.c != 6 || g9.d != 7) { return 18; }
    g9.a = 7; g9.a++;
    if (g9.a != -8) { return 19; }             /* 8 does not fit in 4 bits */
    g9.b = -8; g9.b--;
    if (g9.b != 7) { return 20; }

    /* a value too wide for the field is truncated, not shifted into a neighbour */
    g1.a = 9; g1.b = 31;
    if (g1.a != 1 || g1.b != 31) { return 21; }

    /* copies and initializer images carry the packed unit */
    g6.a = 11; g6.b = 6; g6.n = 12;
    if (g6.a != 11 || g6.b != 6 || g6.n != 12) { return 22; }
    l.a = 3; l.b = 9;
    copy = l;
    if (copy.a != 3 || copy.b != 9) { return 23; }
    if (init1.a != 5 || init1.b != 17) { return 24; }
    if (init6.a != 3 || init6.b != 9 || init6.n != 77) { return 25; }
    if (init9.a != 1 || init9.b != 2 || init9.c != 3 || init9.d != 4) {
        return 26;
    }
    l.a = 5; l.b = 17;
    if (l.a != 5 || l.b != 17) { return 27; }

    /* one unit, two signednesses: each field keeps its own reading */
    g10.a = -3; g10.b = 5;
    if (g10.a != -3 || g10.b != 5) { return 34; }
    g10.b = 7;
    if (g10.a != -3 || g10.b != 7) { return 35; }

    printf("%d %d %d %d %d %d\n", g1.a, g1.b, g9.a, g9.c, init1.b, init6.n);
    printf("mix %d %d %d %d\n", g10.a, g10.b, (int)sizeof(struct B11),
           (int)sizeof(struct B13));
    g9.a = -5;                      /* int:4 is signed, so the sign survives */
    if (g9.a != -5) { return 28; }
    return 96;
}
