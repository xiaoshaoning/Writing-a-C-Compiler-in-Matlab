int main() {
    int x; int y;
    x = 0; y = 5;
    if ((x = 1) || (y = 9)) { }   /* short-circuit: RHS skipped */
    return x * 100 + y;           /* 105 (1*100 + 5), not 109 */
}
