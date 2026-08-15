struct P { int x; int y; };
struct P gp = { 5, 6 };
int main() {
    return gp.x * 10 + gp.y;     /* global struct: 56 */
}
