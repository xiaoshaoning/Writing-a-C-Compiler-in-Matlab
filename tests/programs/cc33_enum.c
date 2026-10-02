/* cc33_enum.c - enums: a definition registers its constants, and the tag
 * names a type (an int) usable for variables, parameters and typedefs.
 * Exit 96. */
#include <stdio.h>
enum Colour { RED, GREEN = 5, BLUE };
typedef enum { LOW, HIGH = 9 } Level;
enum Colour next(enum Colour c) { return c; }
int main() {
    enum Colour c = BLUE;           /* RED=0, GREEN=5, BLUE=6 */
    Level l = HIGH;                 /* 9 */
    enum Colour d;
    d = GREEN;                      /* 5 */
    if (c != 6) { return 1; }
    if (l != 9) { return 2; }
    if (d != 5) { return 3; }
    if (next(RED) != 0) { return 4; }
    if (GREEN + BLUE != 11) { return 5; }
    printf("%d %d %d\n", c, l, d);
    return 96;
}
