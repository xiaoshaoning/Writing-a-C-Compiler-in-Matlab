int even(int n) { if (n == 0) { return 1; } return odd(n - 1); } int odd(int n) { if (n == 0) { return 0; } return even(n - 1); } int main() { return even(10) * 10 + even(7); }
