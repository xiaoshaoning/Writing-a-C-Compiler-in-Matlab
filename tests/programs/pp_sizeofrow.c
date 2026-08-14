// sizeof of a multi-dim row (int[3] = 24) vs element (8); char row = 3.
int a[2][3];
char c[2][3];
int main() { return sizeof(a[0]) / sizeof(a[0][0]) * 10 + sizeof(c[0]); }
