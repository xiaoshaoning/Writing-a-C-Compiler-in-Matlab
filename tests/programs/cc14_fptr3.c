int add(int a, int b) { return a + b; } int sub(int a, int b) { return a - b; } int main() { int (*fp)(int, int); int r; fp = add; r = fp(10, 5); fp = sub; r = r * 10 + fp(10, 5); return r; }
