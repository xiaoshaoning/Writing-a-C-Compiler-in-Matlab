// Partial initializer: remaining elements are zero-initialized (C semantics).
int main() { int a[3] = {7, 14}; return a[0] + a[1]*10 + a[2]; }
