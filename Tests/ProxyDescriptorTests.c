// SPDX-License-Identifier: GPL-3.0-or-later
#include "ProxyTunnelBridge.h"
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <sys/stat.h>
int main(int argc, char **argv) {
    assert(argc == 4);
    char path[104]; snprintf(path, sizeof(path), "%s/fd.sock", argv[2]);
    int receiver = VPTBindFDReceiver(path); assert(receiver >= 0);
    int pipes[2]; assert(pipe(pipes) == 0);
    assert(write(pipes[1], "fixtureFD", 9) == 9); close(pipes[1]);
    assert(VPTSendFD(path, pipes[0]) == 0); close(pipes[0]);
    int received = VPTReceiveFD(receiver); assert(received >= 0);
    int32_t child = 0; assert(VPTSpawn(argv[1], argv[2], argv[3], received, &child) == 0); close(received);
    for (int i = 0; i < 100 && VPTPollChild(child); i++) usleep(50000);
    struct stat info; assert(stat(argv[3], &info) == 0 && info.st_size == 17);
    close(receiver); unlink(path);
    puts("Unix descriptor transfer and restricted child descriptor inheritance passed");
    return 0;
}
