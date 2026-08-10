int sum(int *p, int n) { int i; int s; s = 0; i = 0; while (i < n) { s = s + p[i]; i = i + 1; } return s; }
int a[5];
int main() { a[0] = 1; a[1] = 3; a[2] = 5; a[3] = 7; a[4] = 9; return sum(a, 5); }
