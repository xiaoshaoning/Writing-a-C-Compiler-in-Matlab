int main() {
    enum { RED, GREEN, BLUE };    /* local enum */
    int c;
    c = BLUE;
    return c + RED;               /* 2 */
}
