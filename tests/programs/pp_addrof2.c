// & on a bare global array name: address-of no-op path (decay to pointer).
int a[2];
int main() { int *p;
  p = &a;
  *p = 7;
  *(p + 1) = 8;
  return *p * 10 + *(p + 1);
}
