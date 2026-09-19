/* cc21_wordloc.c - local width-type declarations, including 'word'
 * (cc_int's 4-byte extension, not C), so this is simulator-only: gcc
 * cannot parse 'word' and the interpreter has no short/word/long.
 * Exit 0. */
int main() {
    word w = 300000;
    long l = 5;
    short s = 70000;            /* 16-bit store truncation: 4464 */
    if (w != 300000) { return 1; }
    if (l != 5) { return 2; }
    if (s != 4464) { return 3; }
    if (sizeof(word) != 4) { return 4; }
    if (sizeof(short) != 2) { return 5; }
    return 0;
}
