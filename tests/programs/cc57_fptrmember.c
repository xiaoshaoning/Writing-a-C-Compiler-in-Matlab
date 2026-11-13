/* cc57_fptrmember.c - a function pointer as a struct member.
 *
 * `struct S { int (*f)(int); }` did not parse: the member parser was the last copy
 * of the declarator shape and it had no parenthesised form. Making it parse exposed
 * the real defect, which was NOT where it looked:
 *
 *   elseif etype >= 1000 && ~is_ptr_code(etype)
 *       estruc = 1;                 % a struct member: address, no load
 *
 * A function-pointer type is 2000 + the return type: >= 1000, and not a pointer
 * code. So the member access took the STRUCT branch and emitted the member's ADDRESS
 * where its VALUE was due - `p = s.f;` became `movq &s, p`, a silent wrong answer.
 * The predicate that knows the difference is is_struct_code(), which excludes both
 * pointer and function-pointer codes, and it existed all along. That test was spelled
 * out by hand in SIX places, and every one had the same hole.
 *
 * Every expression is well-defined C, so gcc's answer is the spec. Exit 96.
 */
int printf(const char *, ...);

typedef int (*FP)(int);
struct S { FP f; int n; };
struct T { struct S s; };
struct A { FP a[2]; };
FP gp;
struct S gs;
int inc(int x) { return x + 1; }
int dbl(int x) { return x * 2; }
int main(void) {
    struct S s; struct T t; struct A arr; FP p; int (*q)(int);
    s.f = inc; s.n = 5;
    if (s.f(41) != 42) { return 1; }
    t.s.f = dbl;
    if (t.s.f(21) != 42) { return 2; }
    if ((int)sizeof(s.f) != 8) { return 3; }
    p = s.f;
    if (p(0) != 1) { return 4; }
    q = t.s.f;
    if (q(4) != 8) { return 5; }
    arr.a[0] = inc; arr.a[1] = dbl;
    if (arr.a[0](9) != 10) { return 6; }
    if (arr.a[1](9) != 18) { return 7; }
    gs.f = dbl; gs.n = 7;
    if (gs.f(gs.n) != 14) { return 8; }
    { struct S *ps; ps = &s; if (ps->f(1) != 2) { return 9; } }
    if (s.n != 5) { return 10; }
    return 96;
}
