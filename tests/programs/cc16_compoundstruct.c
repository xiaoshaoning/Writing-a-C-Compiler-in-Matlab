struct W { int a; } w = { 6 };     /* compound file-scope struct */
int main() {
    return w.a;                    /* 6 */
}
