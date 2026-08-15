char gs[16];
int main() {
    gs = "hello";
    return gs[0] * 10 + gs[1];       /* 104 * 10 + 101 = 1141 -> 117 */
}
