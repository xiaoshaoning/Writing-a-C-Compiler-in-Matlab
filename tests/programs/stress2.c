/* stress2.c — a ~450-line torture program for the three-track toolchain.
 * Runs identically through:
 *   xc ('tests/programs/stress2.c')                    — interpreter
 *   cc_int -> gcc -> stress2.exe                       — compiler + gcc
 *   cc_int -> x86sim('stress2.s')                      — compiler + simulator
 * Only the shared dialect is used (no structs/switch/for/unsigned), so
 * all three tracks must print the same output and return the checksum.
 *
 * Sections: string library, five sorts + searches, 3x3 matrix algebra,
 * number theory, bit tricks, string analysis, a parallel-array
 * "database", and a final accumulating checksum.
 */

/* ------------------------- string library ------------------------- */

int str_len(char *s) {
    int n;
    n = 0;
    while (s[n] != 0) {
        n = n + 1;
    }
    return n;
}

void str_cpy(char *d, char *s) {
    int i;
    i = 0;
    while (s[i] != 0) {
        d[i] = s[i];
        i = i + 1;
    }
    d[i] = 0;
}

int str_cmp(char *a, char *b) {
    int i;
    i = 0;
    while (a[i] != 0 && b[i] != 0 && a[i] == b[i]) {
        i = i + 1;
    }
    return a[i] - b[i];
}

void str_cat(char *d, char *s) {
    int n;
    int i;
    n = str_len(d);
    i = 0;
    while (s[i] != 0) {
        d[n + i] = s[i];
        i = i + 1;
    }
    d[n + i] = 0;
}

int str_chr(char *s, char c) {
    int i;
    i = 0;
    while (s[i] != 0) {
        if (s[i] == c) {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

void str_rev(char *s) {
    int n;
    int i;
    char t;
    n = str_len(s);
    i = 0;
    while (i < n / 2) {
        t = s[i];
        s[i] = s[n - 1 - i];
        s[n - 1 - i] = t;
        i = i + 1;
    }
}

int str_is_pal(char *s) {
    int n;
    int i;
    n = str_len(s);
    i = 0;
    while (i < n / 2) {
        if (s[i] != s[n - 1 - i]) {
            return 0;
        }
        i = i + 1;
    }
    return 1;
}

/* ------------------------- sorting + search ------------------------- */

void sort_bubble(int *a, int n) {
    int i;
    int j;
    int t;
    i = 0;
    while (i < n - 1) {
        j = 0;
        while (j < n - 1 - i) {
            if (a[j] > a[j + 1]) {
                t = a[j];
                a[j] = a[j + 1];
                a[j + 1] = t;
            }
            j = j + 1;
        }
        i = i + 1;
    }
}

void sort_insert(int *a, int n) {
    int i;
    int j;
    int key;
    i = 1;
    while (i < n) {
        key = a[i];
        j = i - 1;
        while (j >= 0 && a[j] > key) {
            a[j + 1] = a[j];
            j = j - 1;
        }
        a[j + 1] = key;
        i = i + 1;
    }
}

void sort_select(int *a, int n) {
    int i;
    int j;
    int m;
    int t;
    i = 0;
    while (i < n - 1) {
        m = i;
        j = i + 1;
        while (j < n) {
            if (a[j] < a[m]) {
                m = j;
            }
            j = j + 1;
        }
        t = a[i];
        a[i] = a[m];
        a[m] = t;
        i = i + 1;
    }
}

void qsort_rec(int *a, int lo, int hi) {
    int pivot;
    int i;
    int j;
    int t;
    if (lo >= hi) {
        return;
    }
    pivot = a[hi];
    i = lo;
    j = lo;
    while (j < hi) {
        if (a[j] <= pivot) {
            t = a[i];
            a[i] = a[j];
            a[j] = t;
            i = i + 1;
        }
        j = j + 1;
    }
    t = a[i];
    a[i] = a[hi];
    a[hi] = t;
    qsort_rec(a, lo, i - 1);
    qsort_rec(a, i + 1, hi);
}

void merge_rec(int *a, int lo, int mid, int hi, int *tmp) {
    int i;
    int j;
    int k;
    i = lo;
    j = mid + 1;
    k = lo;
    while (i <= mid && j <= hi) {
        if (a[i] <= a[j]) {
            tmp[k] = a[i];
            i = i + 1;
        } else {
            tmp[k] = a[j];
            j = j + 1;
        }
        k = k + 1;
    }
    while (i <= mid) {
        tmp[k] = a[i];
        i = i + 1;
        k = k + 1;
    }
    while (j <= hi) {
        tmp[k] = a[j];
        j = j + 1;
        k = k + 1;
    }
    k = lo;
    while (k <= hi) {
        a[k] = tmp[k];
        k = k + 1;
    }
}

void msort_rec(int *a, int lo, int hi, int *tmp) {
    int mid;
    if (lo >= hi) {
        return;
    }
    mid = (lo + hi) / 2;
    msort_rec(a, lo, mid, tmp);
    msort_rec(a, mid + 1, hi, tmp);
    merge_rec(a, lo, mid, hi, tmp);
}

int search_lin(int *a, int n, int x) {
    int i;
    i = 0;
    while (i < n) {
        if (a[i] == x) {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

int search_bin(int *a, int n, int x) {
    int lo;
    int hi;
    int mid;
    lo = 0;
    hi = n - 1;
    while (lo <= hi) {
        mid = (lo + hi) / 2;
        if (a[mid] == x) {
            return mid;
        }
        if (a[mid] < x) {
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    return -1;
}

/* ------------------------- matrix algebra ------------------------- */

void mat_mul(int *c, int *a, int *b) {
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

void mat_transpose(int *c, int *a) {
    int i;
    int j;
    i = 0;
    while (i < 3) {
        j = 0;
        while (j < 3) {
            c[i * 3 + j] = a[j * 3 + i];
            j = j + 1;
        }
        i = i + 1;
    }
}

int mat_det3(int *a) {
    return a[0] * (a[4] * a[8] - a[5] * a[7]) -
           a[1] * (a[3] * a[8] - a[5] * a[6]) +
           a[2] * (a[3] * a[7] - a[4] * a[6]);
}

int mat_trace(int *a) {
    return a[0] + a[4] + a[8];
}

/* ------------------------- number theory ------------------------- */

int gcd(int m, int n) {
    if (n == 0) {
        return m;
    }
    return gcd(n, m % n);
}

int lcm(int m, int n) {
    return m / gcd(m, n) * n;
}

int fact(int n) {
    if (n <= 1) {
        return 1;
    }
    return n * fact(n - 1);
}

int fib_iter(int n) {
    int a;
    int b;
    int c;
    int i;
    a = 0;
    b = 1;
    i = 0;
    while (i < n) {
        c = a + b;
        a = b;
        b = c;
        i = i + 1;
    }
    return a;
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

int powmod(int base, int exp, int mod) {
    int r;
    r = 1;
    while (exp > 0) {
        if (exp & 1) {
            r = r * base % mod;
        }
        base = base * base % mod;
        exp = exp >> 1;
    }
    return r;
}

int sum_divisors(int n) {
    int s;
    int i;
    s = 0;
    i = 1;
    while (i <= n) {
        if (n % i == 0) {
            s = s + i;
        }
        i = i + 1;
    }
    return s;
}

int totient(int n) {
    int r;
    int i;
    r = n;
    i = 2;
    while (i * i <= n) {
        if (n % i == 0) {
            while (n % i == 0) {
                n = n / i;
            }
            r = r / i * (i - 1);
        }
        i = i + 1;
    }
    if (n > 1) {
        r = r / n * (n - 1);
    }
    return r;
}

int reverse_digits(int n) {
    int r;
    r = 0;
    while (n != 0) {
        r = r * 10 + n % 10;
        n = n / 10;
    }
    return r;
}

/* ------------------------- bit tricks ------------------------- */

int popcount(int n) {
    int c;
    c = 0;
    while (n != 0) {
        c = c + (n & 1);
        n = n >> 1;
    }
    return c;
}

int next_pow2(int n) {
    int r;
    r = 1;
    while (r < n) {
        r = r << 1;
    }
    return r;
}

int rotate_left(int v, int n) {
    int k;
    k = n & 31;
    return (v << k) | (v >> (32 - k));
}

int gray(int n) {
    return n ^ (n >> 1);
}

/* ------------------------- string analysis ------------------------- */

int count_words(char *s) {
    int n;
    int in;
    int i;
    n = 0;
    in = 0;
    i = 0;
    while (s[i] != 0) {
        if (s[i] == ' ') {
            in = 0;
        } else if (in == 0) {
            in = 1;
            n = n + 1;
        }
        i = i + 1;
    }
    return n;
}

void count_letters(char *s, int *freq) {
    int i;
    i = 0;
    while (i < 26) {
        freq[i] = 0;
        i = i + 1;
    }
    i = 0;
    while (s[i] != 0) {
        if (s[i] >= 'a' && s[i] <= 'z') {
            freq[s[i] - 'a'] = freq[s[i] - 'a'] + 1;
        }
        i = i + 1;
    }
}

/* ------------------------- "database" ------------------------- */

int db_find(int *keys, int *vals, int n, int k) {
    int i;
    i = 0;
    while (i < n) {
        if (keys[i] == k) {
            return vals[i];
        }
        i = i + 1;
    }
    return -1;
}

int db_sum(int *vals, int n) {
    int s;
    int i;
    s = 0;
    i = 0;
    while (i < n) {
        s = s + vals[i];
        i = i + 1;
    }
    return s;
}

/* ------------------------- main ------------------------- */

int main() {
    int checksum;
    int i;
    int w;
    char buf[256];
    char buf2[256];
    char words[96];
    int data[12];
    int bub[12];
    int ins[12];
    int sel[12];
    int qck[12];
    int mrg[12];
    int tmp[12];
    int m1[9];
    int m2[9];
    int m3[9];
    int freq[26];
    int dbk[6];
    int dbv[6];

    checksum = 0;

    /* --- strings --- */
    str_cpy(buf, "the quick brown fox jumps over the lazy dog");
    checksum = checksum + str_len(buf);
    str_cpy(buf2, buf);
    str_cat(buf2, " again");
    checksum = checksum + str_len(buf2);
    checksum = checksum + str_chr(buf, 'q');
    checksum = checksum + str_cmp(buf, buf2);
    str_cpy(words, "never odd or even");
    checksum = checksum + str_is_pal(words);
    printf("len=%d len2=%d q=%d cmp=%d pal=%d\n",
           str_len(buf), str_len(buf2), str_chr(buf, 'q'),
           str_cmp(buf, buf2), str_is_pal(words));

    /* --- sorts: five algorithms on the same scrambled array --- */
    i = 0;
    while (i < 12) {
        data[i] = (i * 7 + 3) % 13 - 3;
        bub[i] = data[i];
        ins[i] = data[i];
        sel[i] = data[i];
        qck[i] = data[i];
        mrg[i] = data[i];
        i = i + 1;
    }
    sort_bubble(bub, 12);
    sort_insert(ins, 12);
    sort_select(sel, 12);
    qsort_rec(qck, 0, 11);
    msort_rec(mrg, 0, 11, tmp);
    checksum = checksum + bub[11] + ins[0] + sel[6] + qck[9] + mrg[2];
    printf("bubble: %d %d %d %d %d %d %d %d %d %d %d %d\n",
           bub[0], bub[1], bub[2], bub[3], bub[4], bub[5],
           bub[6], bub[7], bub[8], bub[9], bub[10], bub[11]);
    printf("agree=%d\n",
           bub[0] == ins[0] && ins[0] == sel[0] && sel[0] == qck[0] &&
           qck[0] == mrg[0]);

    /* --- search --- */
    checksum = checksum + search_lin(bub, 12, 5);
    checksum = checksum + search_bin(bub, 12, 7);
    checksum = checksum + search_bin(bub, 12, 42);
    printf("lin5=%d bin7=%d bin42=%d\n",
           search_lin(bub, 12, 5), search_bin(bub, 12, 7),
           search_bin(bub, 12, 42));

    /* --- matrices --- */
    i = 0;
    while (i < 9) {
        m1[i] = i + 1;
        m2[i] = 9 - i;
        i = i + 1;
    }
    mat_mul(m3, m1, m2);
    mat_transpose(m1, m3);
    checksum = checksum + mat_trace(m3) + mat_det3(m1) + m1[8];
    printf("trace=%d det=%d c88=%d\n", mat_trace(m3), mat_det3(m1), m1[8]);

    /* --- number theory --- */
    checksum = checksum + gcd(12345, 67890);
    checksum = checksum + lcm(12, 18);
    checksum = checksum + fact(9);
    checksum = checksum + fib_iter(20);
    checksum = checksum + powmod(3, 100, 1000);
    checksum = checksum + sum_divisors(28);
    checksum = checksum + totient(100);
    checksum = checksum + reverse_digits(123456789);
    w = 0;
    i = 2;
    while (i < 100) {
        if (is_prime(i)) {
            w = w + 1;
        }
        i = i + 1;
    }
    checksum = checksum + w;
    printf("gcd=%d lcm=%d fact9=%d fib20=%d pow=%d sd=%d tot=%d rev=%d pr=%d\n",
           gcd(12345, 67890), lcm(12, 18), fact(9), fib_iter(20),
           powmod(3, 100, 1000), sum_divisors(28), totient(100),
           reverse_digits(123456789), w);

    /* --- bit tricks --- */
    checksum = checksum + popcount(43690);
    checksum = checksum + next_pow2(1000);
    checksum = checksum + rotate_left(1, 17);
    checksum = checksum + gray(42);
    printf("pop=%d np2=%d rot=%d gray=%d\n",
           popcount(43690), next_pow2(1000),
           rotate_left(1, 17), gray(42));

    /* --- string analysis --- */
    checksum = checksum + count_words(buf);
    count_letters(buf, freq);
    checksum = checksum + freq[4] + freq[14] + freq[20];
    printf("words=%d e=%d o=%d t=%d\n",
           count_words(buf), freq[4], freq[14], freq[20]);

    /* --- the database --- */
    i = 0;
    while (i < 6) {
        dbk[i] = 10 * (i + 1);
        dbv[i] = (i + 1) * (i + 1);
        i = i + 1;
    }
    checksum = checksum + db_find(dbk, dbv, 6, 40);
    checksum = checksum + db_find(dbk, dbv, 6, 77);
    checksum = checksum + db_sum(dbv, 6);
    printf("find40=%d find77=%d dbsum=%d\n",
           db_find(dbk, dbv, 6, 40), db_find(dbk, dbv, 6, 77),
           db_sum(dbv, 6));

    printf("final checksum=%d\n", checksum);
    return checksum;
}
