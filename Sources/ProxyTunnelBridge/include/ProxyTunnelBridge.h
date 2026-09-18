// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef VP_TUN_BRIDGE_H
#define VP_TUN_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
int VPTCreate(char *name, size_t capacity);
int VPTName(int fd, char *name, size_t capacity);
int VPTBindFDReceiver(const char *path);
int VPTSendFD(const char *path, int descriptor);
int VPTReceiveFD(int socket);
int VPTSpawn(const char *executable, const char *work, const char *config, int tunFD, int32_t *pid);
int VPTPollChild(int32_t pid);
typedef struct { uint16_t source_port; uint8_t ipv6; char path[1024]; } VPTLocalProcess;
int VPTLocalProcesses(uint16_t proxy_port, VPTLocalProcess *results, int capacity);
#endif
