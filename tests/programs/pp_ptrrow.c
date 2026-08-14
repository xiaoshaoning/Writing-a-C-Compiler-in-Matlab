// Pointer-to-row: &a[0] indexes rows; &a is a pointer to the whole array.
int a[2][3];
int main() {
  a[0][0] = 1;
  a[1][0] = 2;
  return (&a[0])[1][0] * 10 + (&a)[0][1][0];
}
