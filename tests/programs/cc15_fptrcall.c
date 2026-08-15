int add2(int a, int b) { return a + b; }
int main() {
    int (*fp)(int, int);
    fp = add2;
    return (*fp)(10, 5);           /* deref + call: 15 */
}
