struct P { int x; };
int main() {
    struct P p; struct P *q;
    p.x = 7;
    q = &p;
    return q->x;                 /* -> on a struct pointer: 7 */
}
