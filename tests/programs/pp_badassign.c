// Negative: a non-lvalue on the left of '=' must error (the operand-value
// collision also let (9) = 5 through the assignment's lvalue check).
int main() { (9) = 5; return 1; }
