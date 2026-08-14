// & on a bare local array name: address-of no-op path (LEA address).
int main() { int a[2]; int *p;
  p = &a;
  *p = 3;
  *(p + 1) = 4;
  return *p * 10 + *(p + 1);
}
