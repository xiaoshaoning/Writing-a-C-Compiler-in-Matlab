struct P { int x; int y; };
struct P mk(int v) { struct P r; r.x = v; r.y = v * 2; return r; }
int main() {
    struct P (*fp)(int);
    struct P p;
    fp = mk;
    p = fp(4);                     /* struct result assigned */
    return p.x * 10 + p.y;         /* 48 */
}
