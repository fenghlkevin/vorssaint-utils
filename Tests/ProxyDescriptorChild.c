// SPDX-License-Identifier: GPL-3.0-or-later
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 5) return 2;
    char bytes[32] = {0};
    if (read(3, bytes, sizeof(bytes)) != 9 || memcmp(bytes, "fixtureFD", 9)) return 3;
    int output = open(argv[4], O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (output < 0) return 4;
    if (write(output, "descriptor passed", 17) != 17) return 5;
    close(output); return 0;
}
