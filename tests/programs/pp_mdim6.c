// Pointer difference across multi-dim rows (row stride 3 elements).
int main() { int a[2][3]; int *p; int *q;
  p = &a[0][0];
  q = &a[1][0];
  return q - p;
}
