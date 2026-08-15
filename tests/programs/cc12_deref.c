struct P { int x; }; int main() { struct P p; struct P *q; p.x = 7; q = &p; (*q).x = 8; return (*q).x; }
