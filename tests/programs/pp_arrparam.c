// int array parameter decays to a pointer.
int sum(int a[3]) { return a[0] + a[1] + a[2]; }
int main() { int x[3]; x[0] = 1; x[1] = 2; x[2] = 3; return sum(x); }
