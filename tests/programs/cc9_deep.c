int count(int n) { if (n == 0) { return 0; } return 1 + count(n - 1); } int main() { return count(100); }
