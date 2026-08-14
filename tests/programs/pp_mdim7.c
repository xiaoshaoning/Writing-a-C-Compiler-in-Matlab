// A multi-dim row used directly as a pointer.
int a[2][3];
int main() { int *p;
  a[1][0] = 11;
  a[1][1] = 12;
  p = a[1];
  return p[0] + p[1];
}
