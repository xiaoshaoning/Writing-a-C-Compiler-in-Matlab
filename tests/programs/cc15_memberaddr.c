struct P { int x; };
int main() {
    struct P p; int *q;
    p.x = 9;
    q = &p.x;
    return *q;                   /* member address: 9 */
}
