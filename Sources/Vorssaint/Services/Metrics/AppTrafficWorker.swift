// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

// The signal handler only writes a machine integer. Cleanup runs in the poll loop.
private nonisolated(unsafe) var appTrafficWorkerStopping: Int32 = 0

/// Owns the PTY and nettop even if the GUI is SIGKILLed during replacement.
/// stdin is a dedicated parent lifeline; stdout carries CSV back to the GUI.
enum AppTrafficWorker {
    static func run(parentPID: Int32) -> Int32 {
        guard parentPID > 1, getppid() == parentPID else { return 2 }
        appTrafficWorkerStopping = 0
        signal(SIGTERM) { _ in appTrafficWorkerStopping = 1 }
        signal(SIGINT) { _ in appTrafficWorkerStopping = 1 }
        signal(SIGHUP) { _ in appTrafficWorkerStopping = 1 }
        signal(SIGPIPE, SIG_IGN)
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return 3 }
        let input = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        child.arguments = NetworkProcessSupport.appTrafficArguments
        child.standardInput = terminal
        child.standardOutput = terminal
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { return 4 }
        try? terminal.close()
        defer {
            // Keep the master alive until the child is dead. Closing it first
            // makes nettop spin on EOF instead of waiting for a refresh.
            if child.isRunning {
                child.terminate()
                let deadline = ProcessInfo.processInfo.systemUptime + 0.5
                while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
            try? input.close()
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while appTrafficWorkerStopping == 0 && getppid() == parentPID && child.isRunning {
            var descriptors = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0),
                               pollfd(fd: master, events: Int16(POLLIN | POLLHUP), revents: 0)]
            let ready = poll(&descriptors, 2, 250)
            if ready < 0 { if errno == EINTR { continue }; return 5 }
            if descriptors[0].revents != 0 {
                var byte: UInt8 = 0
                if Darwin.read(STDIN_FILENO, &byte, 1) <= 0 { return 0 }
            }
            if descriptors[1].revents & Int16(POLLIN) != 0 {
                let count = Darwin.read(master, &buffer, buffer.count)
                guard count > 0 else { return 0 }
                let forwarded = buffer.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    var offset = 0
                    while offset < count {
                        let sent = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), count - offset)
                        if sent < 0 { if errno == EINTR && appTrafficWorkerStopping == 0 { continue }; return false }
                        if sent == 0 { return false }
                        offset += sent
                    }
                    return true
                }
                if !forwarded { return 0 }
            } else if descriptors[1].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return 0 }
        }
        return 0
    }
}
