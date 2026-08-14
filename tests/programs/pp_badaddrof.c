// Negative: & on a non-lvalue must error ("bad address of").
int main() { return &(1 + 2); }
