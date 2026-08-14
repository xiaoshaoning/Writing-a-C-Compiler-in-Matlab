// Address-of a fully-indexed multi-dim element; pointer arithmetic on it.
int main() { int a[2][3]; int *p;
  p = &a[0][0];
  *p = 5;
  *(p + 1) = 6;
  return *p * 10 + *(p + 1);
}
