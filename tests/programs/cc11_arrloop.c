int main() { int a[5]; int i; int s; i = 0; while (i < 5) { a[i] = i * i; i = i + 1; } i = 0; s = 0; while (i < 5) { s = s + a[i]; i = i + 1; } return s; }
