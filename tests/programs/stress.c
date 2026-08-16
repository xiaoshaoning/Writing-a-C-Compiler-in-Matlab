/* stress.c — a ~200-line stress program for the three-track toolchain.
 * Runs identically through:
 *   xc ('tests/programs/stress.c')                    — interpreter
 *   cc_int -> gcc -> stress.exe                       — compiler + gcc
 *   cc_int -> x86sim('stress.s')                      — compiler + simulator
 * Uses only the shared dialect (no structs/switch/for), so all three
 * tracks must print the same output and return the same checksum.
 */

int a[12] = {5, 3, 8, 1, 9, 2, 7, 4, 6, 0, 11, 10};
int b[12];

int strlen2(char *s) {
    int n;
    n = 0;
    while (s[n] != 0) {
        n = n + 1;
    }
    return n;
}

void strcpy2(char *dst, char *src) {
    int i;
    i = 0;
    while (src[i] != 0) {
        dst[i] = src[i];
        i = i + 1;
    }
    dst[i] = 0;
}

int strcmp2(char *p, char *q) {
    int i;
    i = 0;
    while (p[i] != 0 && q[i] != 0 && p[i] == q[i]) {
        i = i + 1;
    }
    return p[i] - q[i];
}

int gcd(int m, int n) {
    if (n == 0) {
        return m;
    }
    return gcd(n, m % n);
}

int fact(int n) {
    if (n <= 1) {
        return 1;
    }
    return n * fact(n - 1);
}

int fib(int n) {
    if (n <= 1) {
        return 1;
    }
    return fib(n - 1) + fib(n - 2);
}

int is_prime(int n) {
    int d;
    if (n < 2) {
        return 0;
    }
    d = 2;
    while (d * d <= n) {
        if (n % d == 0) {
            return 0;
        }
        d = d + 1;
    }
    return 1;
}

void insertion_sort(int *arr, int n) {
    int i;
    int j;
    int key;
    i = 1;
    while (i < n) {
        key = arr[i];
        j = i - 1;
        while (j >= 0 && arr[j] > key) {
            arr[j + 1] = arr[j];
            j = j - 1;
        }
        arr[j + 1] = key;
        i = i + 1;
    }
}

int binary_search(int *arr, int n, int x) {
    int lo;
    int hi;
    int mid;
    lo = 0;
    hi = n - 1;
    while (lo <= hi) {
        mid = (lo + hi) / 2;
        if (arr[mid] == x) {
            return mid;
        }
        if (arr[mid] < x) {
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    return -1;
}

void matrix_mul(int *c, int *a, int *b) {
    int i;
    int j;
    int k;
    int s;
    i = 0;
    while (i < 3) {
        j = 0;
        while (j < 3) {
            s = 0;
            k = 0;
            while (k < 3) {
                s = s + a[i * 3 + k] * b[k * 3 + j];
                k = k + 1;
            }
            c[i * 3 + j] = s;
            j = j + 1;
        }
        i = i + 1;
    }
}

int popcount(int n) {
    int c;
    c = 0;
    while (n != 0) {
        c = c + (n & 1);
        n = n >> 1;
    }
    return c;
}

int main() {
    int i;
    int checksum;
    int primes;
    int m[9];
    int x[9];
    int y[9];
    char buf[64];
    char msg[64];

    checksum = 0;
    primes = 0;

    /* string library */
    strcpy2(buf, "hello, stress!");
    checksum = checksum + strlen2(buf);
    printf("len=%d cmp=%d cmp2=%d\n", strlen2(buf),
           strcmp2(buf, "hello, stress!"), strcmp2(buf, "hello"));

    /* recursion: gcd, factorial, fibonacci */
    checksum = checksum + gcd(48, 36);
    checksum = checksum + fact(7);
    checksum = checksum + fib(10);
    printf("gcd=%d fact=%d fib=%d\n", gcd(48, 36), fact(7), fib(10));

    /* primes and popcount over a range */
    i = 0;
    while (i < 40) {
        if (is_prime(i)) {
            primes = primes + 1;
        }
        checksum = checksum + popcount(i);
        i = i + 1;
    }
    printf("primes<40=%d checksum=%d\n", primes, checksum);

    /* sort the global array */
    i = 0;
    while (i < 12) {
        b[i] = a[i];
        i = i + 1;
    }
    insertion_sort(b, 12);
    checksum = checksum + b[0] + b[11];
    printf("sorted: %d %d %d %d %d %d %d %d %d %d %d %d\n",
           b[0], b[1], b[2], b[3], b[4], b[5],
           b[6], b[7], b[8], b[9], b[10], b[11]);
    printf("find(7)=%d find(20)=%d\n", binary_search(b, 12, 7),
           binary_search(b, 12, 20));

    /* 3x3 matrix multiplication */
    x[0] = 1; x[1] = 2; x[2] = 3;
    x[3] = 4; x[4] = 5; x[5] = 6;
    x[6] = 7; x[7] = 8; x[8] = 9;
    y[0] = 9; y[1] = 8; y[2] = 7;
    y[3] = 6; y[4] = 5; y[5] = 4;
    y[6] = 3; y[7] = 2; y[8] = 1;
    matrix_mul(m, x, y);
    checksum = checksum + m[0] + m[4] + m[8];
    printf("m00=%d m11=%d m22=%d\n", m[0], m[4], m[8]);

    /* string round-trip */
    strcpy2(msg, buf);
    msg[5] = 'X';
    printf("msg=%s\n", msg);

    /* arithmetic soup */
    checksum = checksum + (a[5] * 3 - a[1] / 2) + (a[9] << 2) + (a[3] % 4);
    checksum = checksum + (fib(6) > 10) + (gcd(14, 7) == 7) * 5;

    printf("final checksum=%d\n", checksum);
    return checksum;
}
