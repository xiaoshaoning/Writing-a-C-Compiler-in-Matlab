/* cc37_static.c - static locals live in the data section: they keep their
 * value across calls, are zero-initialized without an initializer, and each
 * function has its own. Exit 96. */
#include <stdio.h>
int calls;
int counter(void) { static int n = 0; n = n + 1; calls = calls + 1; return n; }
int tick(void) { static int m; m = m + 2; return m; }
int main() {
    int i, a, b;
    for (i = 0; i < 4; i++) { counter(); }
    if (calls != 4) { return 1; }
    if (tick() != 2 || tick() != 4) { return 2; }
    if (counter() != 5) { return 3; }
    a = counter();               /* 6 */
    b = tick();                  /* 6 */
    if (calls != 6) { return 4; }
    printf("%d %d %d\n", calls, a, b);
    return 96;
}
