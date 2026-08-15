struct Inner { int a; int b; };
struct Outer { struct Inner in; int c; };
int main() {
    struct Outer o;
    o.in.a = 3;
    o.in.b = 4;
    o.c = 5;
    return o.in.a * 100 + o.in.b * 10 + o.c;   /* 345 */
}
