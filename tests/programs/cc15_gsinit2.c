struct Inner { int a; int b; };
struct Outer { struct Inner in; int c; };
struct Outer go = { { 3, 4 }, 5 };
int main() {
    return go.in.a * 100 + go.in.b * 10 + go.c;   /* 345 */
}
