/* cc22_escapes.c - C escape sequences in char and string literals.
 * Character values are checked through the exit code and the string bytes
 * through stdout (the suite compares xc against cc_int). Exit 27. */
#include <stdio.h>
int main() {
    char a = '\t';      /* 9  */
    char b = '\r';      /* 13 */
    char c = '\0';      /* 0  */
    char d = '\\';      /* 92 */
    char e = '\'';      /* 39 */
    char f = '\x41';    /* 65 = 'A' */
    char g = '\101';    /* 65 = 'A' */
    if (a != 9) { return 1; }
    if (b != 13) { return 2; }
    if (c != 0) { return 3; }
    if (d != 92) { return 4; }
    if (e != 39) { return 5; }
    if (f != 'A') { return 6; }
    if (g != 'A') { return 7; }
    printf("[\t]\\\"\x41\101\n");
    return (a + b + c + d + e + f + g) % 256;   /* 283 -> 27 */
}
