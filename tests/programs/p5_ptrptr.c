int main() { int a; int *p; int **q; a = 42; p = &a; q = &p; return **q; }
