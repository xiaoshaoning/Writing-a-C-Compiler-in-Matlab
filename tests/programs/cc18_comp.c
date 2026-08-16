struct P { int x; int y; };
int main() {
    struct P p;
    int *q;
    p = (struct P){3, 4};
    q = (int[]){5, 6, 7};
    return p.x * 100 + p.y * 10 + q[2];   /* 347 -> 91 */
}
