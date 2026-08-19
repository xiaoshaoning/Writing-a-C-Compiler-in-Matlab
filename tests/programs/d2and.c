double f2(double a, double b) { return a - b; }
int main() {
    double a = 2.5; double b = -1.25;
    double c = a * b; double e = f2(a, 10);
    if (c < 0 && e < 0) return 42;
    return 1;
}
