/* cc60_scalar_literal.c - compound literals: the scalar form's value is the OBJECT.
 *
 * `(int){5} + 1` returned garbage (156, 188, 252 across three builds - address
 * dependent) where C says 6, and `&(int){9}` returned 9 correctly, which is why it hid:
 * the value was an address, and the one case a person would try is the case where an
 * address is right.
 *
 * The cause was one clause. The array branch of the compound-literal parser accepted
 * `cl_isarr || cbase == 0 || cbase == 1`, so every scalar int or char literal took the
 * ARRAY path, where a literal's value is its own address. The scalar branch below it was
 * never reached - which is why adding a load there changed nothing, and why the earlier
 * attempt at this fix looked inert.
 *
 * A scalar literal's value is the stored object; `&` still yields the object's address,
 * because '&' drops the load through lvalue_addr. The array and struct forms are
 * unaffected: an array literal's value IS its address.
 *
 * Every expression is well-defined C, so gcc's answer is the spec. Exit 96.
 */
int printf(const char *, ...);

struct P { int a; int b; };

int main(void) {
    /* the scalar form: value, not address */
    if ((int){5} + 1 != 6) { return 1; }
    if ((int){-7} != -7) { return 2; }

    /* and its address, which is the same object */
    {
        int *p;
        p = &(int){9};
        if (*p != 9) { return 3; }
        *p = 11;                        /* a compound literal is an lvalue */
        if (*p != 11) { return 4; }
    }

    /* char scalars took the same wrong branch */
    if ((char){65} != 65) { return 5; }

    /* the array form is unchanged: its value is its address, by design */
    {
        int *q;
        q = (int[]){1, 2, 3};
        if (q[0] + q[2] != 4) { return 6; }
        if (q[1] != 2) { return 7; }
    }

    /* and so is the struct form */
    {
        struct P *r;
        r = &(struct P){3, 4};
        if (r->a + r->b != 7) { return 8; }
    }

    printf("scalar literal ok\n");
    return 96;
}
