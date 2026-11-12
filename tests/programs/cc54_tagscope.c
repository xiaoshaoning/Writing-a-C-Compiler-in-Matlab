/* cc54_tagscope.c - a struct/union tag is in scope from the moment it is SEEN.
 *
 * Three shapes were unsupported and are pinned here:
 *
 *   1. `struct Node { struct Node *next; }` - the linked-list idiom. The tag was
 *      registered only after the closing brace, so the member could not name the
 *      type being defined: "unknown tag Node".
 *   2. `typedef struct Node { struct Node *next; } Node;` - the same, through a
 *      typedef, which is the shape the status doc listed as the last gap.
 *   3. `struct A { struct B *b; };` before B is defined - a pointer to an
 *      incomplete type is legal C (6.7.2.3), and the tag is declared by that
 *      mention; only a use that needs B's layout requires the body.
 *
 * Every expression is well-defined C, so gcc's answer is the spec. Exit 96.
 */
int printf(const char *, ...);

/* 1. self-referential, no typedef */
struct Node { struct Node *next; int v; };

/* 2. self-referential, through a typedef */
typedef struct TNode { struct TNode *next; int v; } TNode;

/* 3. a forward tag: B is declared by this mention and defined below */
struct A { struct B *b; int tag; };
struct B { int x; };

/* still fine: anonymous struct/union definitions in a typedef, and a union */
typedef struct { int x; int y; } Pt;
typedef union { int i; char c; } U;
typedef struct { struct { int z; } inner; int w; } Outer;

struct Node gn2, gn1;
TNode gt2, gt1;

int main(void) {
    /* 1. a two-node list walked by the member pointer */
    gn2.v = 5; gn2.next = 0;
    gn1.v = 4; gn1.next = &gn2;
    if (gn1.v != 4) { return 1; }
    if (gn1.next->v != 5) { return 2; }
    if (gn1.next->next != 0) { return 3; }

    /* 2. the same through the typedef, and sizeof of the typedef'd type */
    gt2.v = 7; gt2.next = 0;
    gt1.v = 6; gt1.next = &gt2;
    if (gt1.next->v != 7) { return 4; }
    if ((int)sizeof(TNode) != (int)sizeof(struct TNode)) { return 5; }

    /* 3. the forward tag: a pointer to a type defined later in the file */
    {
        struct B b;
        struct A a;
        b.x = 11;
        a.b = &b;
        a.tag = 12;
        if (a.b->x != 11) { return 6; }
        if (a.tag != 12) { return 7; }
    }

    /* the typedef'd definition kinds that already worked keep working */
    {
        Pt p;
        U u;
        Outer o;
        p.x = 1; p.y = 2;
        u.i = 3;
        o.inner.z = 4; o.w = 5;
        if (p.x + p.y != 3) { return 8; }
        if (u.i != 3) { return 9; }
        if (o.inner.z + o.w != 9) { return 10; }
    }

    /* a 1-element list through a local, so the tag resolves in a frame too */
    {
        struct Node n;
        n.v = 13;
        n.next = &n;                 /* a self-pointer, never dereferenced twice */
        if (n.next->v != 13) { return 11; }
    }

    printf("tagscope ok\n");
    return 96;
}
