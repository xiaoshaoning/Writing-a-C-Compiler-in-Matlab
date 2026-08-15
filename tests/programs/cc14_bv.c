struct P { int x; int y; }; int sum(struct P p) { return p.x + p.y; } int main() { struct P p; p.x = 3; p.y = 4; return sum(p); }
