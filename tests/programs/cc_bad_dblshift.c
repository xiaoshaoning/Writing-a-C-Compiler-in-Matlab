/* cc_bad_dblshift.c - `d <<= 2` on a double, refused on purpose.
 *
 * C requires an integer for <<=, and gcc refuses this. The port used to fall through
 * to the divsd at the end of the double compound-assignment branch, so `d <<= 2`
 * computed d / 2 and said nothing. The suite asserts the refusal so that the branch
 * cannot quietly widen again.
 */
int main(void) {
    double d = 10.0;
    d <<= 2;
    return (int)d;
}
