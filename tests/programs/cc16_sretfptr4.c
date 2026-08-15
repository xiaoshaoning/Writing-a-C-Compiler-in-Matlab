struct P { int x; };
struct P mk(int v) { struct P r; r.x = v; return r; }
struct P (*gfp)(int);
int main() {
    gfp = mk;
    return gfp(6).x;               /* global struct-returning fptr: 6 */
}
