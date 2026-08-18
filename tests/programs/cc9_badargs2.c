// Negative: a FORWARD call with the wrong arg count must error too (the
// arg-count check used to fire only for already-parsed callees).
int main() { return f(1, 2); }
int f(int a) { return a; }
