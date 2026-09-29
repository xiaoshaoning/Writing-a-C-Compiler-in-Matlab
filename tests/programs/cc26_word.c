/* cc26_word.c - `word` (signed 32-bit) and `unsigned word` widen with the
 * right sign. Simulator only: `word` is a cc_int extension, so gcc cannot
 * be the oracle (as with cc21_wordloc.c). Exit 0. */
int main() {
    word w = -1;
    unsigned word uw = 4294967295;
    long a = w;                 /* sign-extend: -1 */
    long b = uw;                /* zero-extend: 4294967295 */
    if (a != -1) { return 1; }
    if (b != 4294967295) { return 2; }
    if (sizeof(word) != 4) { return 3; }
    if (sizeof(unsigned word) != 4) { return 4; }
    return 0;
}
