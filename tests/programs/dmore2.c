/* dmore2.c — which comparison fails? each if returns its numbered code. */
int main() {
    double c = -3.125;
    double d = -1.25;
    double e = -7.5;
    double g = 2.0;
    if (c < 0) return 1;
    if (d > -2) return 2;
    if (e < 0) return 3;
    if (g >= 2) return 4;
    return 9;
}