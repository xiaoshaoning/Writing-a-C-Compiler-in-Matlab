/* cc51_mdimparam.c - a two-dimensional array PARAMETER. `int a[][3]` decays to
 * a pointer to a row, not to a pointer to an int: a[i] steps a whole row and
 * a[i][j] steps within it, so a function can walk a matrix the way C code does.
 * The one- and two-dimensional forms are both exercised, and `sizeof` a decayed
 * parameter is the pointer's 8. Exit 96.
 *
 * Not asserted here, and still a limitation: `&a[0] + 1` (a pointer to a ROW,
 * i.e. int (*)[3]) steps by a pointer instead of a row, and `int (*p)[3]`
 * declarations do not parse. See PROJECT_STATUS. */
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
    if (flat(v, 1) != 0) { return 7; }

    printf("%d %d %d %d\n", rowsum(m, 2), col2(m, 0), flat(v, 4), sz(m));
    return 96;
}
