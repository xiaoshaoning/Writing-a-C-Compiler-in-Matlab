#include <stdio.h>
double f2(double a, double b) {
    return a - b;
}
int main() {
    double a = 2.5;
    double b = -1.25;
    double c = a * b;          /* -3.125 */
    double d = c / 2.5;        /* -1.25 */
    double e = f2(a, 10);      /* -7.5 */
    double g = (a + b) * 2 - 0.5;  /* 2.0 */
    printf("%g %g %g %g %d\n", c, d, e, g, (int) (g + 0.5 * a * a));
    if (c < 0 && d > -2 && e < 0 && g >= 2)
        return 11;
    return 7;
}
