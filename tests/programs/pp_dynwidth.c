// Dynamic width/precision: %*d, %*s, %.2s, %-*d.
int main() {
  printf("[%*d][%*s][%.2s][%-*d]\n", 5, 42, 5, "hi", "hello", 5, 7);
  return 0;
}
