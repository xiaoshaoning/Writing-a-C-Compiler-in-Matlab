int a; int b; int c; int d;
int main() { int *p; int s; p = &a; *p = 1; *(p + 1) = 2; *(p + 2) = 3; *(p + 3) = 4;
  s = p[0] + p[1] + p[2] + p[3]; return s; }
