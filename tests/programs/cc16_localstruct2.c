int main() {
    struct Q { int a; } q;         /* compound local struct def */
    q.a = 8;
    return q.a;                    /* 8 */
}
