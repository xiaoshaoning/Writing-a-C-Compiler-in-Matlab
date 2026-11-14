/* cc59_double_compound.c - compound assignment on a double.
 *
 * `d /= 4.0` was refused while `d = d / 4.0` worked: the double branch handled
 * += -= *= and then failed on /= and %= together, a legal operator lumped in with an
 * illegal one. Splitting them found that %=, <<=, >>=, &=, |= and ^= fell through to
 * the divsd at the end of that branch, so `d <<= 2` silently divided by 2.
 *
 * C requires an integer for those six and gcc refuses them, so they are refused here
 * (the negative check beside cc9_badargs asserts it). What works: /=, and the other
 * three arithmetic forms with an int RHS, which the double branch converts.
 *
 * Every expression is well-defined C, so gcc's answer is the spec. Exit 96.
 */
int printf(const char *, ...);

int main(void) {
    double d = 10.0;
    d /= 4.0;
    if ((int)(d * 10.0) != 25) { return 1; }
    d = 10.0; d += 5;
    if ((int)d != 15) { return 2; }
    d = 10.0; d -= 2.5;
    if ((int)d != 7) { return 3; }
    d = 2.0; d *= 3;
    if ((int)d != 6) { return 4; }
    return 96;
}
