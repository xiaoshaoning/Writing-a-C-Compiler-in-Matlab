double f2(double a, double b) {
    return a - b;
}
int main() {
    double a = 2.5;
    double b = -1.25;
    double c = a * b;
    double d = c / 2.5;
    double e = f2(a, 10);
    double g = (a + b) * 2 - 0.5;
    if (c < 0 && d > -2 && e < 0 && g >= 2) return 11;
    return 7;
}
