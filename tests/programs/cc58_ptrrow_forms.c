/* cc58_ptrrow_forms.c - a pointer to a row in all THREE declarator positions.
 *
 * `int (*p)[3]` has worked as a local for a while (guard cc52). Two positions were
 * still refused, each with its own message:
 *
 *   typedef int (*PA)[3];        a pointer-to-array typedef is not supported
 *   struct S { int (*p)[3]; };   a pointer-to-array member is not supported
 *
 * Both are the same type the variable path builds - pcode(array_type(pcode(elem,
 * depth), dims), 1) - so both now build it the same way, consuming the row's
 * dimensions as the POINTEE's rather than as the declaration's own array dims.
 *
 * The point of a row pointer is that `p + 1` steps a whole row, so every case here
 * checks the step, not just that the declaration parses.
 *
 * Every expression is well-defined C, so gcc's answer is the spec. Exit 96.
 */
int printf(const char *, ...);

typedef int (*PA)[3];          /* the typedef form */

struct S { int (*p)[3]; };     /* the member form */

int a[2][3] = {{1, 2, 3}, {4, 5, 6}};

PA gpa;                        /* a global through the alias */

int main(void) {
    /* typedef: p + 1 must step one row, so (*p)[0] after the step is a[1][0] */
    {
        PA p;
        p = &a[0];
        if ((*p)[0] != 1) { return 1; }
        p = p + 1;
        if ((*p)[0] != 4) { return 2; }
        if ((*p)[2] != 6) { return 3; }
        if ((int)sizeof(PA) != 8) { return 4; }
        if ((int)sizeof(*p) != 12) { return 5; }
    }

    /* member: the same step through the member, and p[i][j] */
    {
        struct S s;
        s.p = &a[0];
        if ((*s.p)[1] != 2) { return 6; }
        s.p = s.p + 1;
        if ((*s.p)[1] != 5) { return 7; }
        if (s.p[0][2] != 6) { return 8; }
    }

    /* the global alias, and a local 2-D array behind a row pointer */
    {
        PA q;
        int b[2][3];
        gpa = &a[1];
        if ((*gpa)[0] != 4) { return 9; }
        q = &b[0];
        b[1][2] = 42;
        if ((*(q + 1))[2] != 42) { return 10; }
    }

    printf("ptrrow forms ok\n");
    return 96;
}
