// unsigned comparisons of values >= 2^32 need the full 64-bit borrow:
// the sim's CF once came from the low 32 bits only.  unsigned long long is
// 64-bit here and under gcc, unlike unsigned long (32-bit under Windows
// gcc).  /* 1 */
int main() {
    unsigned long long a;
    unsigned long long b;
    a = 4294967296;
    b = 4294967295;
    return a > b;
}
