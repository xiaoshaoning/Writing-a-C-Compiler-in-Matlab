/* cc44_enumstatic.c - `enum { A } v;` (a definition followed by a
 * declarator, at file scope and local), and two functions that each keep
 * their OWN `static int n` - the static gets a per-function symbol, so they
 * do not share one variable. Exit 96. */
#include <stdio.h>
enum { TOP = 3 } gt;
int f(void) { static int n = 0; n = n + 1; return n; }
int g(void) { static int n = 100; n = n + 2; return n; }
int main() {
    enum { A = 6 } v;
    static int count = 0;
    int rf, rg;
    v = A;
    gt = TOP;
    if (v != 6 || gt != 3) { return 1; }
    f(); f(); g();
    rf = f();                       /* 3 */
    rg = g();                       /* 104 */
    count = count + 1;
    if (rf != 3 || rg != 104 || count != 1) { return 2; }
    printf("%d %d %d %d\n", v + gt, rf, rg, count);
    return 96;
}
