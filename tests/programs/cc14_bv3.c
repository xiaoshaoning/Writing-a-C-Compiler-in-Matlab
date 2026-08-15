struct P { int x; int y; }; struct P make(int v) { struct P r; r.x = v; r.y = v * 2; return r; } int main() { return make(3).x * 10 + make(4).y; }
