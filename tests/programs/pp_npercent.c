// %n writes the count of characters printed so far to its arg address.
int main() { int n;
  printf("abc%n", &n);
  return n;
}
