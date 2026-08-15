#include <stdio.h>
int main() {
    char *p;
    p = malloc(16);
    memset(p, 65, 4);            /* "AAAA" */
    p[4] = 0;
    printf("p=%s len=%d cmp=%d\n", p, printf("x"), memcmp(p, "AAAA", 4));
    exit(42);
    return 0;
}
