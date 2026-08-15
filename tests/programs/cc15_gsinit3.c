struct P { char c; int x; };
struct P gp = { 'A', 7 };
int main() {
    return gp.c + gp.x;          /* 65 + 7 = 72 */
}
