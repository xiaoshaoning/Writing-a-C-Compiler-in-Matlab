// Non-constant global initializer reading another global (was the negative case).
int g = 5;
int h = g;
int main() { return h; }
