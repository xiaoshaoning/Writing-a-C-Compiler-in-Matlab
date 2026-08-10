int main() { int fd; char *buf; int n1; int n2;
  fd = open("tests/programs/p6_data.txt", 0);
  buf = malloc(16);
  n1 = read(fd, buf, 4);
  n2 = read(fd, buf, 16);
  close(fd);
  return n1 * 100 + n2;
}
