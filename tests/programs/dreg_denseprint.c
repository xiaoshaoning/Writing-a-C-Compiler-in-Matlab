/* dreg_denseprint.c - Bug A high-precision float PRINT via x86sim.
 * prints dense doubles at %.17g. Golden stdout (gcc-verified):
 *   a=0.10000000000000001
 *   c=3.1415926535897931
 *   d=0.33333333333333331
 * x86sim used to render ...00142 / ...7930 / ...34281 before the
 * printf-arg transport fix. Exit 42 when reachable. */
#include <stdio.h>
double dec(double a, double b){ return a/b; }
int main(){
    double a = 0.1;
    double pi = 3.141592653589793;
    printf("a=%.17g\n", a);
    printf("c=%.17g\n", pi);
    printf("d=%.17g\n", dec(1.0,3.0));
    return 42;
}
