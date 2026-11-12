/* cc52_ptrrow.c - a pointer to a ROW: `int (*p)[3]`.
 *
 * This was recorded as the last known limitation: the type model had no way to
 * say "pointer to int[3]", so `int (*p)[3]` did not parse and `p + 1` stepped
 * four bytes instead of a whole row. It works now, and nothing in the corpus
 * covered it - the `int (*` matches elsewhere are all function pointers - so a
 * regression would have been silent.
 *
 * Every expression is well-defined C, so gcc's answer is the spec. Exit 96.
 */
int printf(const char *, ...);

int a[2][3] = {{1, 2, 3}, {4, 5, 6}};

int main(void) {
    int (*p)[3];

    /* the declarator itself, and the sizes that follow from it */
    p = &a[0];
    if ((int)sizeof(p) != 8) { return 1; }        /* the pointer */
    if ((int)sizeof(*p) != 12) { return 2; }      /* the row it points at */

    /* dereference reaches the elements */
    if ((*p)[0] != 1) { return 3; }
    if ((*p)[2] != 3) { return 4; }

    /* p + 1 steps a whole row, which is the whole point */
    p = p + 1;
    if ((*p)[0] != 4) { return 5; }
    if ((*p)[2] != 6) { return 6; }

    /* p[i][j] is the ordinary spelling of the same thing */
    if (p[0][1] != 5) { return 7; }
    if (p[-1][2] != 3) { return 8; }

    /* a local 2-D array, so the declarator is exercised in a frame too */
    {
        int b[2][3];
        int (*q)[3] = &b[0];
        b[1][2] = 42;
        if ((*(q + 1))[2] != 42) { return 9; }
        if ((int)sizeof(b) != 24) { return 10; }
    }

    /* the row pointer still indexes like a pointer: q[0] is a whole row */
    {
        int (*r)[3] = &a[0];
        if (r[1][1] != 5) { return 11; }
    }

    printf("ptrrow ok\n");
    return 96;
}
