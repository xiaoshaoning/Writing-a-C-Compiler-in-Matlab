int main() {
    int x; int a;
    a = (x = 5, x + 1);          /* comma: value is x+1 = 6 */
    return a;
}
