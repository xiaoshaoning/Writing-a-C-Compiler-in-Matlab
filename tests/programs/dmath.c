#include <stdio.h>
#include <math.h>
int main() {
    double x = 2.0;
    double y = 3.5;
    printf("%f %f %f %f %f %f\n", x * y, y / x, sin(0.5), sqrt(2), fabs(-2.5), floor(3.7));
    printf("%d %d\n", (int)(x * y + 0.5), (int)ceil(3.2));
    return 8;
}
