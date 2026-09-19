// SPDX-License-Identifier: GPL-3.0-or-later
#include "ProxyTunnelBridge.h"
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <sys/kern_control.h>
#include <sys/ioctl.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <net/if.h>
#include <net/if_utun.h>
#include <spawn.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>

int VPTName(int fd, char *name, size_t capacity) {
    socklen_t length = (socklen_t)capacity;
    return getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, name, &length);
}
int VPTCreate(char *name, size_t capacity) {
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    struct ctl_info info = {0};
    strlcpy(info.ctl_name, UTUN_CONTROL_NAME, sizeof(info.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &info) < 0) { close(fd); return -1; }
    struct sockaddr_ctl address = {0};
    address.sc_len = sizeof(address); address.sc_family = AF_SYSTEM;
    address.ss_sysaddr = AF_SYS_CONTROL; address.sc_id = info.ctl_id;
    address.sc_unit = 0; // Kernel allocates an unused utun number.
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0 || VPTName(fd, name, capacity) < 0) { close(fd); return -1; }
    return fd;
}
static int unix_address(const char *path, struct sockaddr_un *address) {
    memset(address, 0, sizeof(*address));
    if (strlen(path) >= sizeof(address->sun_path)) { errno = ENAMETOOLONG; return -1; }
    address->sun_family = AF_UNIX; address->sun_len = sizeof(*address);
    strlcpy(address->sun_path, path, sizeof(address->sun_path)); return 0;
}
static void control_options(int fd) {
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct timeval timeout = {35, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}
int VPTControlListen(const char *path) {
    struct sockaddr_un address;
    if (unix_address(path, &address) < 0) return -1;
    struct stat info;
    if (lstat(path, &info) == 0) {
        if (!S_ISSOCK(info.st_mode) || info.st_uid != getuid()) { errno = EACCES; return -1; }
        if (unlink(path) < 0) return -1;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    control_options(fd);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0 || chmod(path, 0600) < 0 || listen(fd, 8) < 0) { close(fd); return -1; }
    return fd;
}
int VPTControlConnect(const char *path) {
    struct sockaddr_un address;
    if (unix_address(path, &address) < 0) return -1;
    struct stat info;
    if (lstat(path, &info) < 0 || !S_ISSOCK(info.st_mode) || info.st_uid != getuid() || (info.st_mode & 077) != 0) { errno = EACCES; return -1; }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    control_options(fd);
    uid_t uid; gid_t gid;
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0 || getpeereid(fd, &uid, &gid) < 0 || uid != getuid()) { close(fd); return -1; }
    return fd;
}
int VPTControlAccept(int listener) {
    int fd = accept(listener, NULL, NULL);
    if (fd < 0) return -1;
    control_options(fd);
    uid_t uid; gid_t gid;
    if (getpeereid(fd, &uid, &gid) < 0 || uid != getuid()) { close(fd); errno = EACCES; return -1; }
    return fd;
}
int VPTBindFDReceiver(const char *path) {
    struct sockaddr_un address;
    if (unix_address(path, &address) < 0) return -1;
    struct stat info;
    if (lstat(path, &info) == 0) {
        if (!S_ISSOCK(info.st_mode) || info.st_uid != getuid()) { errno = EACCES; return -1; }
        if (unlink(path) < 0) return -1;
    }
    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    struct timeval timeout = {2, 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0 || chmod(path, 0600) < 0) { close(fd); return -1; }
    return fd;
}
int VPTSendFD(const char *path, int descriptor) {
    struct sockaddr_un address;
    if (unix_address(path, &address) < 0) return -1;
    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    char byte = 'T', control[CMSG_SPACE(sizeof(int))] = {0};
    struct iovec io = {&byte, 1}; struct msghdr message = {0};
    message.msg_name = &address; message.msg_namelen = sizeof(address);
    message.msg_iov = &io; message.msg_iovlen = 1; message.msg_control = control; message.msg_controllen = sizeof(control);
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS; header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &descriptor, sizeof(int));
    int result = (int)sendmsg(fd, &message, 0); close(fd); return result == 1 ? 0 : -1;
}
int VPTReceiveFD(int fd) {
    char byte = 0, control[CMSG_SPACE(sizeof(int) * 4)] = {0};
    struct iovec io = {&byte, 1}; struct msghdr message = {0};
    message.msg_iov = &io; message.msg_iovlen = 1; message.msg_control = control; message.msg_controllen = sizeof(control);
    int received = (int)recvmsg(fd, &message, 0), result = -1, count = 0;
    for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header; header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) continue;
        size_t bytes = header->cmsg_len - CMSG_LEN(0);
        for (size_t offset = 0; offset + sizeof(int) <= bytes; offset += sizeof(int)) {
            int value; memcpy(&value, (char *)CMSG_DATA(header) + offset, sizeof(value)); count++;
            if (count == 1) result = value; else close(value);
        }
    }
    if (received != 1 || byte != 'T' || count != 1 || (message.msg_flags & MSG_CTRUNC)) { if (result >= 0) close(result); errno = EINVAL; return -1; }
    fcntl(result, F_SETFD, FD_CLOEXEC); return result;
}
int VPTSpawn(const char *executable, const char *work, const char *config, int tunFD, int32_t *pid) {
    // Keep the core in the supervisor's process group so launchd also reaps it
    // after a supervisor crash. Foundation.Process creates a separate group.
    // A negative descriptor starts a regular (non-TUN) core.
    int source = tunFD >= 0 ? fcntl(tunFD, F_DUPFD_CLOEXEC, 10) : -1;
    if (tunFD >= 0 && source < 0) return errno;
    posix_spawn_file_actions_t actions; posix_spawnattr_t attributes;
    posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes);
    int result = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (!result) result = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    if (!result) result = posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    if (!result) result = posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    if (!result && source >= 0) result = posix_spawn_file_actions_adddup2(&actions, source, 3);
    if (!result) result = posix_spawn_file_actions_addchdir_np(&actions, work);
    char *args[] = {(char *)executable, "-d", (char *)work, "-f", (char *)config, NULL};
    char *env[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8", NULL};
    pid_t child = 0;
    if (!result) result = posix_spawn(&child, executable, &actions, &attributes, args, env);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes); if (source >= 0) close(source);
    if (!result) *pid = child; return result;
}
int VPTPollChild(int32_t pid) { int status = 0; pid_t result; do { result = waitpid(pid, &status, WNOHANG); } while (result < 0 && errno == EINTR); return result == 0 ? 1 : 0; }

// Read-only lookup of this user's loopback TCP clients; no elevated privileges.
#include <libproc.h>
#include <netinet/in.h>
int VPTExecutablePath(char *path, size_t capacity) {
    return proc_pidpath(getpid(), path, (uint32_t)capacity);
}
int VPTLocalProcesses(uint16_t proxy_port, VPTLocalProcess *results, int capacity) {
    if (!results || capacity <= 0 || !proxy_port) return 0;
    pid_t pids[4096];
    int bytes = proc_listpids(PROC_UID_ONLY, getuid(), pids, sizeof(pids));
    if (bytes > sizeof(pids)) bytes = sizeof(pids);
    int count = 0;
    for (int i = 0; i < bytes / (int)sizeof(pid_t) && count < capacity; i++) {
        struct proc_fdinfo descriptors[4096];
        int size = proc_pidinfo(pids[i], PROC_PIDLISTFDS, 0, descriptors, sizeof(descriptors));
        char path[1024] = {0};
        for (int j = 0; j < size / (int)sizeof(struct proc_fdinfo) && count < capacity; j++) {
            if (descriptors[j].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
            struct socket_fdinfo socket = {0};
            if (proc_pidfdinfo(pids[i], descriptors[j].proc_fd, PROC_PIDFDSOCKETINFO, &socket, sizeof(socket)) != sizeof(socket)) continue;
            if (socket.psi.soi_kind != SOCKINFO_TCP) continue;
            struct in_sockinfo *ip = &socket.psi.soi_proto.pri_tcp.tcpsi_ini;
            if (ntohs((uint16_t)ip->insi_fport) != proxy_port) continue;
            int loopback = (ip->insi_vflag & INI_IPV4) && ntohl(ip->insi_laddr.ina_46.i46a_addr4.s_addr) == INADDR_LOOPBACK
                && ntohl(ip->insi_faddr.ina_46.i46a_addr4.s_addr) == INADDR_LOOPBACK;
            loopback |= (ip->insi_vflag & INI_IPV6) && IN6_IS_ADDR_LOOPBACK(&ip->insi_laddr.ina_6) && IN6_IS_ADDR_LOOPBACK(&ip->insi_faddr.ina_6);
            if (!loopback) continue;
            if (!path[0] && proc_pidpath(pids[i], path, sizeof(path)) <= 0) break;
            results[count].source_port = ntohs((uint16_t)ip->insi_lport);
            results[count].ipv6 = (ip->insi_vflag & INI_IPV6) && IN6_IS_ADDR_LOOPBACK(&ip->insi_laddr.ina_6);
            strlcpy(results[count].path, path, sizeof(results[count].path));
            count++;
        }
    }
    return count;
}
