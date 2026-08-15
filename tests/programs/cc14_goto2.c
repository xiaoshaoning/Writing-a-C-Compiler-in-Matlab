int main() { int i; int s; s = 0; for (i = 0; i < 5; i++) { if (i == 3) { goto end; } s = s + i; } end: return s; }
