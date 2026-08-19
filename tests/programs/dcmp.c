/* dcmp.c — double comparison smoke: return 42 when z > 1.5. */
int main() {
    double z = 3.75;
    if (z > 1.5)
        return 42;
    return 1;
}