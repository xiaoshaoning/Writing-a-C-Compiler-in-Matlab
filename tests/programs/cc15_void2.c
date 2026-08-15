void set(int *p, int v) { *p = v; }
int main() {
    int x;
    set(&x, 5);
    return x;                    /* 5 */
}
