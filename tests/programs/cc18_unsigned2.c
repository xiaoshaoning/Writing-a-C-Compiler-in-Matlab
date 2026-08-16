int main() {
    unsigned int a;
    int b;
    unsigned int c;
    a = 3000000000;
    b = 5;
    c = a >> 1;
    return (c == 1500000000) + (a > b ? 10 : 0) + ((a / b) == 600000000 ? 100 : 0);
                               /* 111 */
}
