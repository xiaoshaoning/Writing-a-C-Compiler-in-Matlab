int a; int b; int c;
int main() { int *p; a = 10; b = 20; c = 30; p = &a; return p[0] + p[1] + p[2]; }
