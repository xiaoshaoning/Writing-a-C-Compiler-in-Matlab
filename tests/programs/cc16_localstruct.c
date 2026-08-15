int main() {
    struct Q { int a; int b; };   /* local struct definition */
    struct Q q;
    q.a = 3;
    q.b = 4;
    return q.a * 10 + q.b;        /* 34 */
}
