int main() { int x; int *p; int **q; x = 5; p = &x; q = &p; return **q; }
