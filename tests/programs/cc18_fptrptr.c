int *inc(int *p) { *p = *p + 1; return p; }
int main() {
    int x;
    int *(*fp)(int *);
    x = 5;
    fp = inc;
    fp(&x);
    return x;                   /* 6 */
}
