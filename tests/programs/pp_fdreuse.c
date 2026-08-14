// fd registry reuse: 20 open/close cycles must not hit the 16-fd cap.
int main() { int i; int fd;
  i = 0;
  while (i < 20) {
    fd = open("tests/programs/p6_data.txt", 0);
    if (fd < 0) return 1;
    close(fd);
    i = i + 1;
  }
  return 0;
}
