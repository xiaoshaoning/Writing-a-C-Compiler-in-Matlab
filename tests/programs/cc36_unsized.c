/* cc36_unsized.c - `char s[] = "...";`: the string's length sets the array
 * size, the terminating NUL included, and an escape counts as one byte.
 * Exit 96. */
#include <stdio.h>
#include <string.h>
int main() {
    char s[] = "abc";
    char t[] = "a\tb";
    if (sizeof(s) != 4) { return 1; }
    if (strlen(s) != 3) { return 2; }
    if (sizeof(t) != 4) { return 3; }
    if (t[1] != '\t') { return 4; }
    s[1] = 'X';
    if (strcmp(s, "aXc") != 0) { return 5; }
    printf("%s %d %d\n", s, (int)sizeof(s), (int)sizeof(t));
    return 96;
}
