// Brace elision: inner groups align to sub-array boundaries, scalars continue flat.
int a[2][3] = {{1,2},{3}};
int main() { return a[0][1] * 100 + a[1][0] * 10 + a[0][2]; }
