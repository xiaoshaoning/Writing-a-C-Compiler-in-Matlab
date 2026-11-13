/* cc55_typedefs.c - one typedef, several declarators.
 *
 * `typedef struct { … } T, *PT;` was the last gap the status doc listed: the
 * typedef branch read exactly one declarator, then expected the ';' and reported
 * "expected token 59, got 44". A typedef declares a LIST, and the '*' and '['
 * belong to each declarator rather than to the typedef - `typedef int A, *PA,
 * B[3];` names three different types - so the branch loops now.
 *
 * Every expression is well-defined C, so gcc's answer is the spec. Exit 96.
 */
int printf(const char *, ...);

/* the shape that was unsupported: a definition and a pointer to it, one typedef */
typedef struct { int x; int y; } T, *PT;

/* and a self-referential one, which is only possible because the tag is in scope
   before its body (cc54 covers that; this covers the second declarator) */
typedef struct Node { struct Node *next; int v; } Node, *PNode;

/* three declarators: a scalar, a pointer and an array */
typedef int A, *PA, B[3];

/* a union, so the same loop is exercised on the other definition kind */
typedef union { int i; char c; } U, V;

T gt;
B gb;

int main(void) {
    /* the definition and its pointer, from one typedef */
    {
        T t;
        PT pt;
        t.x = 1;
        t.y = 2;
        pt = &t;
        if (pt->x != 1) { return 1; }
        if (pt->y != 2) { return 2; }
        if ((int)sizeof(T) != 8) { return 3; }
        if ((int)sizeof(PT) != 8) { return 4; }
    }

    /* the second declarator of a self-referential struct */
    {
        Node n2;
        Node n1;
        PNode pn;
        n2.v = 5;
        n2.next = 0;
        n1.v = 4;
        n1.next = &n2;
        pn = &n1;
        if (pn->v != 4) { return 5; }
        if (pn->next->v != 5) { return 6; }
    }

    /* a scalar, a pointer and an array out of one typedef */
    {
        A a;
        PA pa;
        B b;
        a = 7;
        pa = &a;
        if (*pa != 7) { return 7; }
        b[0] = 8;
        b[2] = 9;
        if (b[0] != 8 || b[2] != 9) { return 8; }
        if ((int)sizeof(B) != 12) { return 9; }      /* int[3] */
        if ((int)sizeof(A) != 4) { return 10; }
    }

    /* a union, twice from one typedef */
    {
        U u;
        V v;
        u.i = 10;
        v.i = 11;
        if (u.i + v.i != 21) { return 11; }
        if ((int)sizeof(U) != 4) { return 12; }
    }

    /* file-scope declarators from those typedefs still work */
    gt.x = 13;
    gb[1] = 14;
    if (gt.x != 13) { return 13; }
    if (gb[1] != 14) { return 14; }

    printf("typedefs ok\n");
    return 96;
}
