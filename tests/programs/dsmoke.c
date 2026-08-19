/* dsmoke.c — double arithmetic smoke test (exit code + printf parity). */
#include <stdio.h>

double add2(double a, double b) {
    return a + b;
}

int main() {
    double x = 2.5;
    double y = 1.25;
    double z = x * 2 + y / 0.5 - add2(x, y);
    printf("%f %g %e %d\n", z, x, y, (int) z);
    if (z > 1.5 && z < 10.5)
        return 3;
    return 1;
}