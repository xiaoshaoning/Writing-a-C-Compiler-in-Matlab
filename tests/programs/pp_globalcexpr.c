// global constant-expression initializers evaluate at compile time
// (used to die with a cryptic "bad global declaration").
int x = 1 + 2;
int main() { return x; }   /* 3 */
