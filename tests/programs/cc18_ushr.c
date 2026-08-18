// unsigned >>= must be a LOGICAL shift: -2 (2^64-2) >>= 1 is 2^63-1,
// which is != -1; an arithmetic shift gives -1 == -1.  /* 0 */
int main() {
    unsigned int u;
    u = 0 - 2;
    u >>= 1;
    return u == -1;
}
