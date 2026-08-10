int main() { int fd; char *buf; int n;
  fd = open("tests/programs/p6_data.txt", 0);
  if (fd < 0) return 99;
  buf = malloc(16);
  n = read(fd, buf, 16);
  close(fd);
  if (n != 10) return 98;
  return memcmp(buf, "hello data", 10);
}
