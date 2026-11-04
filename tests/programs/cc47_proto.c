/* cc47_proto.c - a prototype without a body is a declaration, not a
 * definition. It may carry unnamed parameters and a variadic tail
 * (`int printf(const char *, ...);` is how C declares printf without a
 * header), and it must not register the function: the definition does that,
 * and calling an undeclared/undefined function is still an error.
 * Mutual recursion is the case that needs it in practice. Exit 96. */
#include <stdio.h>
int printf(const char *, ...);          /* unnamed + variadic */

int even(int);                          /* unnamed, body comes later */
int odd(int n);                         /* named: same meaning */

int main() {
    int i;
    for (i = 0; i < 4; i = i + 1) {
        printf("%d%d", even(i), odd(i));
    }
    printf("\n");
    if (even(10) != 1) { return 1; }
    if (odd(11) != 1) { return 2; }
    if (even(11) != 0) { return 3; }
    if (odd(7) != 1) { return 4; }
    if (even(7) != 0) { return 5; }
    return 96;
}

int even(int n) {
    if (n == 0) { return 1; }
    return odd(n - 1);
}

int odd(int n) {
    if (n == 0) { return 0; }
    return even(n - 1);
}
