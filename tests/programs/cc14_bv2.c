struct P { int x; }; struct P make(int v) { struct P r; r.x = v; return r; } int main() { struct P p; p = make(42); return p.x; }
