int f(int x) { return x * 2; } int main() { int (*fp)(int); fp = f; return fp(21); }
