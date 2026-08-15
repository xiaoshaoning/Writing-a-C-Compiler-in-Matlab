struct P { int x; int y; }; int main() { struct P p; struct P *pp; p.x = 5; p.y = 6; pp = &p; return pp->x * 10 + pp->y; }
