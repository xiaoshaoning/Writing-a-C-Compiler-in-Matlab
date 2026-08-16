int main() {
    unsigned int a;
    unsigned int b;
    a = 5; b = 2;
    return a / b + (a < b) + (a > b) * 2 + (a >> 1);   /* 6 */
}
