struct P { int x; int y; };
struct P mk(int a, int b) { struct P r; r.x = a; r.y = b; return r; }
int main() {
    struct P (*fp)(int, int);
    fp = mk;
    return fp(3, 5).x * 10 + fp(6, 1).y;   /* 30 + 1 = 31 */
}
