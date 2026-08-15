// C remainder semantics with negative divisors (regression for cdivmod).
int main() { return (7 % -2) * 100 + (-7 % 2) * 10 + (-7 % -2); }
