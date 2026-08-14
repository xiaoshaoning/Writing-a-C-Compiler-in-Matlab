// Multi-dim row decays to a pointer when passed to a function.
int get(int a[3]) { return a[2]; }
int main() { int m[2][3]; m[0][2] = 9; m[1][2] = 3; return get(m[0]) * 10 + get(m[1]); }
