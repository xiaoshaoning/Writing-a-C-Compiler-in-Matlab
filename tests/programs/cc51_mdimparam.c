/* cc51_mdimparam.c - a two-dimensional array PARAMETER. `int a[][3]` decays to
 * a pointer to a row, not to a pointer to an int: a[i] steps a whole row and
 * a[i][j] steps within it, so a function can walk a matrix the way C code does.
 * The one- and two-dimensional forms are both exercised, and `sizeof` a decayed
 * parameter is the pointer's 8. Exit 96.
 *
 * Also here: a pointer to a ROW. `&a` on an int[3] has type int (*)[3], so
 * `&a + 1` steps a whole array; `int (*p)[3]` is a declarator and `p[i]`/`(*p)`
 * yield the row - and the same shape works as a PARAMETER, because a
 * declarator's head (its stars and the `(*`) is parsed once for both. */
int printf(const char *, ...);

int rowsum(int a[][3], int rows) {
    int i, j, s = 0;
    for (i = 0; i < rows; i = i + 1) {
        for (j = 0; j < 3; j = j + 1) {
            s = s + a[i][j];
        }
    }
    return s;
}

int col2(int a[][3], int row) {
    return a[row][2];
}

int rowsum2(int (*p)[3], int rows) { /* the same thing, spelled as a pointer */
    int i, j, s = 0;
    for (i = 0; i < rows; i = i + 1) {
        for (j = 0; j < 3; j = j + 1) {
            s = s + p[i][j];
        }
    }
    return s;
}

int flat(int a[], int n) {          /* the 1-D form still means int * */
    int i, s = 0;
    for (i = 0; i < n; i = i + 1) {
        s = s + a[i];
    }
    return s;
}

int sz(int a[][3]) {                /* a decayed parameter is a pointer */
    return (int)sizeof(a);
}

int main() {
    int m[2][3];
    int v[4];
    int i, j;

    for (i = 0; i < 2; i = i + 1) {
        for (j = 0; j < 3; j = j + 1) {
            m[i][j] = i * 3 + j + 1;
        }
    }
    for (i = 0; i < 4; i = i + 1) {
        v[i] = i * 10;
    }

    if (rowsum(m, 2) != 21) { return 1; }      /* 1+2+3+4+5+6 */
    if (col2(m, 1) != 6) { return 2; }
    if (flat(v, 4) != 60) { return 3; }        /* 0+10+20+30 */
    if (sz(m) != 8) { return 4; }
    if (m[1][0] != 4) { return 5; }

    /* the same array through both spellings */
    if (rowsum(m, 1) != 6) { return 6; }
    if (rowsum2(m, 2) != 21) { return 15; }   /* int (*p)[3] as a parameter */
    if (flat(v, 1) != 0) { return 7; }

    /* a pointer to a row: &a steps a whole array, and int (*p)[3] indexes it */
    {
        int one[3];
        int (*p)[3];
        int (*q)[3];
        one[0] = 5; one[1] = 6; one[2] = 7;
        if ((int)((char *)(&one + 1) - (char *)&one) != 12) { return 8; }
        if ((int)sizeof(&one) != 8) { return 9; }
        p = &one;
        if ((*p)[1] != 6) { return 10; }
        if (p[0][2] != 7) { return 11; }
        if ((int)sizeof(p) != 8) { return 12; }
        q = m;
        if (q[1][0] != 4) { return 13; }
        if ((int)((char *)(q + 1) - (char *)q) != 12) { return 14; }
    }

    printf("%d %d %d %d\n", rowsum(m, 2), col2(m, 0), flat(v, 4), sz(m));
    return 96;
}
