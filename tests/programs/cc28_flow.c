/* cc28_flow.c - a non-void body may return anywhere: several top-level
 * returns, and labels / dead code after one (the parser used to stop at the
 * first top-level `return`). `extern` is accepted as a no-op qualifier.
 * Exit 96. */
#include <stdio.h>
extern int gext;
int find(int x) {
    if (x > 0) {
        return 1;
    }
    return 2;
}
int first(void) {
    goto skip;
    return 7;                 /* dead code after the goto */
skip:
    return 3;
}
int main() {
    int r;
    r = find(1) + find(-1) + first();   /* 1 + 2 + 3 */
    if (r != 6) { return 1; }
    printf("%d\n", r);
    return 96;
}
