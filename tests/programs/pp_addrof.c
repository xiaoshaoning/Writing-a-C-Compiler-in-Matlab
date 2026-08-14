// & on an indexed array element: address-of via the LC/LI drop path.
int main() { int a[3]; int *p;
  a[0] = 42;
  p = &a[0];
  return *p;
}
