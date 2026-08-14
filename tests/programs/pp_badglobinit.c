// Negative: non-constant GLOBAL initializer is unsupported (locals support it).
int g;
int h = g;
int main() { return 0; }
