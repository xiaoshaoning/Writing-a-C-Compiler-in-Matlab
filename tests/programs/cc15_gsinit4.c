struct P { int x; int y; };
struct P gp = { 9 };             /* partial: y = 0 */
int main() {
    return gp.x + gp.y;          /* 9 */
}
