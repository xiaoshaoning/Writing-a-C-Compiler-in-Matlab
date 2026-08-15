int add(int a, int b) { return a + b; }
int (*gfp)(int, int);
int main() {
    gfp = add;
    return gfp(2, 3);            /* global function pointer: 5 */
}
