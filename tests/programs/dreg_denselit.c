/* dreg_denselit.c - Bug A dense-double literal VALUE transport. A dense
 * literal (0.1) must equal the computed division 1.0/10.0 exactly (both are
 * the nearest double to 0.1). Regression for sim_num64 + v1.3.47 transport. */
int main() {
    double L = 0.1;
    if (L == 1.0/10.0) return 42;
    return 9;
}
