int swap(int *a, int *b) { int t; t = *a; *a = *b; *b = t; return 1; }
int main() { int x; int y; x = 3; y = 7; swap(&x, &y); return x * 10 + y; }
