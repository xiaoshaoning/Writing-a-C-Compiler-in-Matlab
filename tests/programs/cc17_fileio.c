#include <stdio.h>
int main() {
    int fd; char buf[6];
    fd = open("tests/programs/cc17_tmp.txt", 0);   /* read */
    if (fd < 0) { printf("open-fail\n"); return 1; }
    read(fd, buf, 5);
    buf[5] = 0;
    close(fd);
    printf("%s\n", buf);
    return 0;
}
