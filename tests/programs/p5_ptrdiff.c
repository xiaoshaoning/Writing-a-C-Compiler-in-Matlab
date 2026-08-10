int a; int b;
int main() { int *p; int *q; p = &a; q = &b; return q - p; }
