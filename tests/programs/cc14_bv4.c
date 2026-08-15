struct P { int x; }; int getx(struct P p) { return p.x; } struct P make(int v) { struct P r; r.x = v; return r; } int main() { return getx(make(9)); }
