struct P { int a; int b; }; int sum(struct P *p) { return p->a + p->b; } int main() { struct P p; p.a = 10; p.b = 20; return sum(&p); }
