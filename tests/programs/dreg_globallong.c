/* dreg_globallong.c - Bug B: .quad numeric globals store their full width
 * (was 1 low byte). long gl=100000 must read back as 100000, and a global
 * int array {1,2,3} sums to 321 => return 42. */
long gl = 100000;
int a[3] = {1, 2, 3};
int main() {
    if (gl != 100000) return 9;
    if (a[0] + a[1]*10 + a[2]*100 != 321) return 7;
    return 42;
}
