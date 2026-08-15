struct P { int x; };
struct P make(int v) { struct P r; r.x = v; return r; }
struct P (*fp)(int);
int main() {
    fp = make;
    return fp(7).x;              /* struct-returning call through ptr: 7 */
}
