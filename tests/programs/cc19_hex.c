/* cc19_hex.c - C90 hexadecimal integer literals in both tracks:
 * expressions, a global initializer, an array size, an array initializer
 * and an enum constant. Exit 76. */
int gx = 0x11;                          /* 17 */
int garr[0x3] = {0xA, 0xB, 0xC};        /* size 3; 10, 11, 12 */
enum { HE = 0x20 };                     /* 32 */
int main() {
    int x = 0xF0 | 0x0F;                /* 255 */
    int y = 0x10 + gx;                  /* 16 + 17 = 33 */
    int z = garr[0x1] + HE;            /* 11 + 32 = 43 */
    if (x != 0xFF) { return 1; }
    if ((0x1F & 0x0F) != 0x0F) { return 2; }
    return (y + z) % 256;               /* 76 */
}
