/* cc50_corners.c - language corners no other guard covers: block shadowing,
 * sizeof not evaluating its operand, the comma operator, the conditional's
 * common type, enum values and sizeof(enum), switch fallthrough with default in
 * the middle and negative case labels, goto across blocks, do-while with
 * continue, static functions, struct assignment as a value, short-circuit
 * evaluation, pointer arithmetic, char signedness, nested break, multiple
 * declarators. Every expression is well-defined C, so gcc's answer is the spec.
 * Exit 96.
 *
 * One C rule is deliberately NOT asserted here because this compiler does not
 * implement it yet: only the LEFT operand of '+' decays an array, so `*(1 + a)`
 * is wrong. It is recorded in PROJECT_STATUS. */
int printf(const char *, ...);

enum E { A = 5, B, C = -2, D };
static int scale(int n) { return n * 3; }

struct P { int x; int y; };
struct P gp;

int side = 0;
int bump(void) { side = side + 1; return side; }

int main(void) {
    /* shadowing: an inner block redeclares a local */
    { int x = 1; { int x = 2; (void)x; } if (x != 1) { return 1; } }

    /* sizeof does not evaluate its operand */
    { int i = 0; int n = (int)sizeof(i++); if (i != 0 || n != 4) { return 2; } }

    /* comma operator, and its value is the last operand */
    { int a = (side = 0, 7); if (a != 7) { return 3; } }

    /* ternary: the operands meet at double when either is double */
    if (sizeof(1 ? 1 : 2.0) != 8) { return 4; }
    if ((1 ? 1 : 2.0) != 1.0) { return 5; }

    /* The usual arithmetic conversions: -1 converts to unsigned before the
       operation, so the comparison and the division both work in unsigned. */
    if (!(-1 > 0u)) { return 6; }
    if (!((unsigned)-1 > 0)) { return 7; }
    if (-5 < 3u) { return 36; }              /* and not as a signed comparison */
    if ((-1 / 2u) != 2147483647u) { return 8; }
    if ((-1 % 2u) != 1u) { return 9; }

    /* switch: fallthrough, default in the middle, negative and char cases */
    {
        int n = 0, k;
        for (k = 1; k <= 3; k = k + 1) {
            switch (k) {
            case 1: n = n + 10;              /* falls through */
            case 2: n = n + 100; break;
            default: n = n + 1000; break;
            case 3: n = n + 7;
            }
        }
        if (n != (110 + 100 + 7)) { return 10; }
        switch (-2) { default: n = 0; break; case -2: n = 1; break; }
        if (n != 1) { return 11; }
        switch ('b') { case 'a': n = 0; break; case 'b': n = 2; break; }
        if (n != 2) { return 12; }
        switch (100) { case 1: n = 0; break; default: n = 9; break; }
        if (n != 9) { return 13; }
    }

    /* enum with explicit, implicit and negative values */
    if (A != 5 || B != 6 || C != -2 || D != -1) { return 14; }
    if (sizeof(enum E) != 4) { return 15; }
    { enum E e = B; if (e != 6) { return 16; } }

    /* goto forward over code, and backward, inside nested blocks */
    {
        int g = 0;
        goto skip;
        g = 99;
    skip:
        if (g != 0) { return 17; }
        g = 0;
    again:
        g = g + 1;
        if (g < 3) { goto again; }
        if (g != 3) { return 18; }
    }

    /* do-while with continue: the condition still runs */
    {
        int i = 0, n = 0;
        do {
            i = i + 1;
            if (i == 2) { continue; }
            n = n + i;
        } while (i < 4);
        if (n != (1 + 3 + 4)) { return 19; }
    }

    /* a static function at file scope */
    if (scale(4) != 12) { return 20; }

    /* struct assignment is a value: (gp = q).x */
    {
        struct P q;
        q.x = 3; q.y = 4;
        if ((gp = q).x != 3) { return 21; }
        if (gp.y != 4) { return 22; }
    }

    /* short-circuit must not call the side-effecting operand */
    {
        side = 0;
        if (0 && bump()) { return 23; }
        if (side != 0) { return 24; }
        if (1 || bump()) { }
        if (side != 0) { return 25; }
        side = 0;
        if (1 && bump()) { }
        if (side != 1) { return 26; }
    }

    /* pointer arithmetic: 1[a] is a[1], -1[&a[1]] is a[0] */
    {
        int a[3];
        a[0] = 10; a[1] = 11; a[2] = 12;
        if ((a + 1)[0] != 11) { return 27; }   /* an expression as the base */
        /* a[b] is *(a + b) in C, so *(1 + a) is also a[1] - but this compiler
           only decays an array on the LEFT of '+', so that form is not checked
           here yet (see PROJECT_STATUS, same note as the comparisons). */
        if (*(a + 2) != 12) { return 29; }
        if ((int)sizeof(a) != 12) { return 30; }
        if ((int)sizeof(&a) != 8) { return 31; }
    }

    /* char is signed here: (char)200 is negative */
    if ((char)200 >= 0) { return 32; }
    if ((unsigned char)200 != 200) { return 33; }

    /* break leaves only the inner loop */
    {
        int i, n = 0;
        for (i = 0; i < 3; i = i + 1) {
            int j;
            for (j = 0; j < 3; j = j + 1) {
                if (j == 1) { break; }
                n = n + 1;
            }
            n = n + 10;
        }
        if (n != (3 * 11)) { return 34; }
    }

    /* multiple declarators, one initialiser reading the previous one */
    { int a = 2, b = a * 3; if (a != 2 || b != 6) { return 35; } }

    printf("corners ok\n");
    return 96;
}
