// unsigned comparisons of values >= 2^32 need the full 64-bit borrow:
// the sim's CF once came from the low 32 bits only.  /* 1 */
int main() {
    unsigned int a;
    unsigned int b;
    a = 4294967296;
    b = 4294967295;
    return a > b;
}
