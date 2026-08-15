struct P { int x; };
int gx(struct P p) { return p.x; }
struct P mk(int v) { struct P r; r.x = v; return r; }
int main() {
    struct P (*fp)(int);
    fp = mk;
    return gx(fp(9));              /* struct result as an arg: 9 */
}
