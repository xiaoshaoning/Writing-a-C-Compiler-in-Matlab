/* cc56_fptr_alias.c - a typedef'd function pointer: `typedef int (*FP)(int);`
 *
 * The typedef branch parsed its own declarator and its copy had no parentheses,
 * so this failed with "expected a typedef name" while the identical form on a
 * variable had always worked - the grammar existed twice and the second copy had
 * drifted. All three parsers (variable, parameter, typedef) ask
 * parse_declarator_head now.
 *
 * Not covered here because it does not work yet: a function pointer as a STRUCT
 * MEMBER (`struct S { int (*f)(int); }`) fails with "expected a member name" -
 * the member parser is the remaining copy of the shape. Measured on gcc 42, port
 * "expected a member name" for the plain form, with or without a typedef.
 *
 * Every expression is well-defined C, so gcc's answer is the spec. Exit 96.
 */
int printf(const char *, ...);

typedef int (*FP)(int);
typedef int (*FP2)(int);
typedef int (*FP3)(int), (*FP4)(int);   /* two declarators of the same typedef */

int inc(int x) { return x + 1; }
int dbl(int x) { return x * 2; }

FP gp;                                   /* a global through the alias */

int apply(FP f, int x) { return f(x); }  /* and a parameter */

int main(void) {
    FP a;
    FP2 b;
    FP3 c;
    FP4 d;

    a = inc;
    gp = a;
    b = dbl;
    c = inc;
    d = dbl;

    if ((int)sizeof(FP) != 8) { return 1; }
    if (apply(gp, 41) != 42) { return 2; }     /* global, through a parameter */
    if (apply(b, 21) != 42) { return 3; }      /* a second alias of the same type */
    if (apply(a, 0) != 1) { return 4; }
    if (c(4) != 5) { return 5; }               /* two declarators, one typedef */
    if (d(4) != 8) { return 6; }
    if (gp(9) != 10) { return 7; }

    printf("fptr alias ok\n");
    return 96;
}
