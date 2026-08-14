// Three-dimension nested initializer.
int a[2][2][2] = {{{1,2},{3,4}},{{5,6},{7,8}}};
int main() { return a[1][1][1] * 10 + a[0][0][0]; }
