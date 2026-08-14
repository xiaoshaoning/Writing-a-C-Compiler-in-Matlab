// sizeof on an array name (total bytes) and on an expression.
int a[4];
int main() { int g; return sizeof(a) / sizeof(g); }
