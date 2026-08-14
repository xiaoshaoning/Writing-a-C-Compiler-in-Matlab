// Non-constant global initializer via a function call.
int f() { return 42; }
int h = f();
int main() { return h; }
