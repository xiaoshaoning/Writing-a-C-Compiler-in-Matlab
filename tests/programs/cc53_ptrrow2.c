/* cc53_ptrrow2.c - the same row pointer built by ADDRESS-OF, no declarator.
 *
 * `&a[0]` on an `int[2][3]` is an `int (*)[3]`, so `&a[0] + 1` must step twelve
 * bytes and `(*(&a[0] + 1))[1]` must reach a[1][1]. That is the other half of
 * the limitation cc52 covers, and the half with no type written down, so it
 * exercises the address-of path rather than the parser.
 *
 * Every expression is well-defined C, so gcc's answer is the spec. Exit 96.
 */
int printf(const char *, ...);

int a[2][3] = {{1, 2, 3}, {4, 5, 6}};

int main(void) {
    /* one row on: a[1][1] */
    if ((*(&a[0] + 1))[1] != 5) { return 1; }

    /* dereference once more and the row's first element is a[1][0] */
    if (*(*(&a[0] + 1)) != 4) { return 2; }

    /* zero rows on: still a[0] */
    if ((*(&a[0]))[2] != 3) { return 3; }

    /* sizeof of the two things the expression has */
    if ((int)sizeof(&a[0]) != 8) { return 4; }    /* a pointer */
    if ((int)sizeof(a[0]) != 12) { return 5; }    /* a row */

    /* the row a pointer points at is itself an array: a[0][2] the long way */
    if (*(&a[0][0] + 2) != 3) { return 6; }

    /* a local array, so the same expression is built in a frame */
    {
        int b[2][3];
        int k;
        for (k = 0; k < 6; k = k + 1) { (&b[0][0])[k] = k * 2; }
        if ((*(&b[0] + 1))[0] != 6) { return 7; }
        if ((*(&b[0] + 1))[2] != 10) { return 8; }
    }

    printf("ptrrow2 ok\n");
    return 96;
}
