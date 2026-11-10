import Foundation
import Darwin

@main struct AppTrafficLiveTests {
    static func main() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        precondition(openpty(&master, &slave, nil, nil, nil) == 0)
        let reader = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let writer = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        task.arguments = NetworkProcessSupport.appTrafficArguments
        task.standardInput = writer
        task.standardOutput = writer
        task.standardError = FileHandle.nullDevice
        try task.run()
        try writer.close()
        defer { if task.isRunning { task.terminate() }; try? reader.close() }
        // A known local-only transfer proves that proxy-style loopback traffic
        // reaches the same per-process counters used by the app.
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-c", """
import socket, threading, time
server = socket.socket()
server.bind(('127.0.0.1', 0))
server.listen(1)
def receive():
    conn, _ = server.accept()
    while conn.recv(65536):
        pass
    conn.close()
thread = threading.Thread(target=receive)
thread.start()
time.sleep(2)
client = socket.create_connection(server.getsockname())
for _ in range(40):
    client.sendall(b'x' * 65536)
    time.sleep(0.1)
client.close()
thread.join()
server.close()
"""]
        fixture.standardOutput = FileHandle.nullDevice
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate() } }
        let start = Date()
        var captured = Data()
        while Date().timeIntervalSince(start) < 10 {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 500) > 0 {
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(master, &bytes, bytes.count)
                if count > 0 { captured.append(contentsOf: bytes.prefix(count)) }
            }
        }
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(task.processIdentifier, RUSAGE_INFO_CURRENT, $0)
            }
        }
        let text = String(decoding: captured, as: UTF8.self)
        let sections = text.components(separatedBy: "time,,bytes_in,bytes_out,").count - 1
        let samples = text.components(separatedBy: .newlines).compactMap {
            NetworkProcessSupport.sample(fromCSVLine: $0)
        }
        let localBytes = samples.filter { $0.pid == fixture.processIdentifier }.reduce(0) { $0 + $1.bytesIn + $1.bytesOut }
        precondition(localBytes >= 2_621_440, "local proxy-style transfer must be counted under its originating process")
        precondition(sections >= 3, "nettop must deliver samples promptly, even on quiet networks")
        precondition(result == 0)
        let cpuSeconds = Double(info.ri_user_time + info.ri_system_time) / 1_000_000_000
        precondition(cpuSeconds < 1, "nettop must not busy-loop on stdin EOF")
        print("Live app traffic: \(sections) sections in 10s; loopback \(Int(localBytes)) bytes; nettop CPU \(String(format: "%.3f", cpuSeconds)) seconds; passed")
    }
}
