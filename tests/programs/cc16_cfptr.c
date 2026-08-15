char upper(char c) { return c - 32; }
int main() {
    char (*fp)(char);
    fp = upper;
    return fp('a');                /* char-returning fptr: 65 */
}
