int main() {
    enum { A = 5, B = A + 2, C };
    int x;
    x = C;                        /* 8 */
    return x - B + A;             /* 8 - 7 + 5 = 6 */
}
