/* cc_badfptr_member.c - a function-pointer struct member, refused on purpose.
 *
 * The parser reads the declarator now (the member copy of the shape was the last
 * one to be unified), but the VALUE path does not carry the type: measured on
 * R2024b's clone and the engine, `p = s.f;` emitted the STRUCT'S ADDRESS where the
 * member's value belongs, and `s.f = g` died in lvalue_addr, which decides
 * lvalue-ness by matching the instructions already emitted.
 *
 * So the declaration is refused with "function-pointer members are not supported
 * yet". This file exists to keep that refusal honest: the suite asserts the message,
 * so making the declaration parse again - before the value path exists - fails a
 * test instead of becoming a silent wrong answer.
 *
 * gcc compiles this happily and returns 0; the port must NOT.
 */
struct S { int (*f)(int); };

int g(int x) { return x + 1; }

int main(void) {
    struct S s;
    s.f = g;
    return s.f(41);
}
