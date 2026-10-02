/* cc42_unsizedg.c - a file-scope `char g[] = "...";` takes its size from the
 * initializer (the terminating NUL included, an escape counting as one
 * byte), and sizeof sees the whole array. Exit 96. */
#include <stdio.h>
char g[] = "abc";
char msg[] = "hello";
char esc[] = "a\tb";
int len(char *s) { int n = 0; while (s[n] != 0) { n = n + 1; } return n; }
int main() {
    if (sizeof(g) != 4) { return 1; }
    if (sizeof(msg) != 6) { return 2; }
    if (sizeof(esc) != 4) { return 3; }
    if (len(msg) != 5) { return 4; }
    if (g[0] != 'a' || g[2] != 'c') { return 5; }
    if (esc[1] != '\t') { return 6; }
    if (msg[4] != 'o') { return 7; }
    printf("%s %s %d %d\n", g, msg, (int)sizeof(g), (int)sizeof(esc));
    return 96;
}
