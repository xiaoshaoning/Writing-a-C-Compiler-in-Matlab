/* cc49_long.c - long is 4 bytes on this target and long long is 8, which is
 * what gcc emits for the Win64 ABI. The value model was LP64-flavoured before
 * (long 8 bytes), so `sizeof(long)`, struct layout with a long member, literal
 * types and long arithmetic all disagreed with gcc. Every number here was
 * measured from gcc: struct { char c; long l; } is 8 with l at 4, while
 * { char c; long long l; } is 16 with l at 8. Exit 96. */
int printf(const char *, ...);

struct L1 { char c; long l; };          /* 8, l at 4: long aligns to 4 */
struct L2 { char c; long long l; };     /* 16, l at 8 */
struct L3 { long l; long long m; };     /* 16, m at 8 */

struct L1 a; struct L2 b; struct L3 c;

int main() {
    if (sizeof(long) != 4) { return 1; }
    if (sizeof(long long) != 8) { return 2; }
    if (sizeof(1L) != 4) { return 3; }          /* L is a long, not a long long */
    if (sizeof(1LL) != 8) { return 4; }
    if (sizeof(1L + 1) != 4) { return 5; }      /* long wins over int */
    if (sizeof(1LL + 1L) != 8) { return 6; }    /* the wider type wins */
    if (sizeof(struct L1) != 8) { return 7; }
    if (sizeof(struct L2) != 16) { return 8; }
    if (sizeof(struct L3) != 16) { return 9; }
    if ((char *)&a.l - (char *)&a != 4) { return 10; }
    if ((char *)&b.l - (char *)&b != 8) { return 11; }
    if ((char *)&c.m - (char *)&c != 8) { return 12; }
    {
        long v = 2147483647;
        v = v + 1;                              /* wraps at 32 bits */
        if (v != -2147483648) { return 13; }
    }
    {
        long long w = 2147483647;
        w = w + 1;                              /* does not wrap */
        if (w <= 0) { return 14; }
    }
    {
        long u = 0;
        u = u - 1;
        if (u != -1) { return 15; }
    }
    {
        long long z = 1;
        int i;
        for (i = 0; i < 40; i = i + 1) { z = z * 2; }
        if (z != 1099511627776LL) { return 16; }   /* 2^40 needs long long */
    }
    a.l = -1; a.c = 7;
    if (a.l != -1 || a.c != 7) { return 17; }
    b.l = -2;
    if (b.l != -2) { return 18; }
    printf("%d %d %d %ld %d\n", (int)sizeof(long), (int)sizeof(long long),
           (int)sizeof(struct L1), a.l, (int)a.c);
    return 96;
}
