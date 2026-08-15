struct I { int a; }; struct O { int b; struct I i; }; int main() { struct O o; o.b = 5; o.i.a = 6; return o.b * 10 + o.i.a; }
