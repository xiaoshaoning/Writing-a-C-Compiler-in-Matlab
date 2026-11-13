/* cc_bad_addrassign.c - assigning through an '&' expression, refused on purpose.
 *
 * `&x = 5` is not a modifiable lvalue in C, and gcc refuses it. The port used to
 * accept it: lvalue_addr treated "the last instruction is a leaq" as "this is an
 * lvalue", which is true for a struct value being stored in place (`a = b`) and
 * false for an address the '&' operator just computed - and it stored 8 bytes
 * through that address without a word. The branch now also requires the
 * expression's type to be a struct value, which is the only case that needs it.
 *
 * The suite asserts the refusal, so the branch cannot quietly widen again.
 */
int x;

int main(void) {
    &x = 5;
    return x;
}
