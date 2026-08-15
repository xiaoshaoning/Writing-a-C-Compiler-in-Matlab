int square(int x) { return x * x; } int main() { int i; int s; i = 0; s = 0; while (i < 5) { s = s + square(i); i = i + 1; } return s; }
