/* cc39_wrap.c - 32-bit intermediate arithmetic: the narrow types wrap where
 * C says they do even though the register is 64 bits wide, and an int
 * product is narrowed BEFORE it is widened into a long. Unsigned wraparound
 * is defined, so it is what the checks use. `volatile` is a no-op
 * qualifier. Exit 96. */
#include <stdio.h>
int gx = 50000;                 /* a global: neither side can fold this */
int main() {
    unsigned u = 0xFFFFFFFFu, w = 65536u, d = 3000000000u;
    unsigned char uc = 200;
    short s = 30000;
    char c = 200;
    volatile int vi = 7;
    if (vi + 0 != 7) { return 1; }                  /* volatile qualifier */
    if (sizeof(u + 1u) != 4) { return 2; }          /* unsigned stays 32 bits */
    if (u + 1u != 0u) { return 3; }                 /* wraps at 32 */
    if (w * w != 0u) { return 4; }
    if (u * 2u != 0xFFFFFFFEu) { return 5; }
    if (d / 3u != 1000000000u) { return 6; }
    if ((u & 0x7FFFFFFFu) != 0x7FFFFFFFu) { return 7; }
    if ((u >> 4) != 0x0FFFFFFFu) { return 8; }
    if (uc + 60 != 260) { return 9; }               /* unsigned char -> int */
    if (s + s != 60000) { return 10; }              /* short -> int */
    if (c != -56) { return 11; }                    /* plain char is signed */
    if (sizeof(c + c) != 4) { return 12; }          /* char promotes to int */
    if ((long)(gx * gx) != -1794967296L) { return 13; }  /* narrowed then widened */
    if (sizeof(1L + 1) != sizeof(long)) { return 14; }   /* long wins */
    printf("%u %u %u %lu %ld\n", u + 1u, w * w, u * 2u, d / 3u, (long)(gx * gx));
    return 96;
}
