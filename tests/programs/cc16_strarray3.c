int main() {
    char a[4][8];
    a[1] = "xy";                  /* copy into a row */
    return a[1][0] + a[1][1];     /* 120 + 121 = 241 */
}
