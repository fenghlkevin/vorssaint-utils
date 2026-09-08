// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct BatteryLaunchDiagnosis {
    let output: String
    let readable: Bool
    private func field(_ name: String) -> String? {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(name + " = ") }.map { String($0.dropFirst(name.count + 3)) }
    }
    var pid: String? { field("pid") }
    var processID: Int32? { pid.flatMap(Int32.init).flatMap { $0 > 1 ? $0 : nil } }
    var build: String { field("parent bundle version") ?? "未知" }
    var failedWithoutProcess: Bool {
        readable && pid == nil && field("job state") == "spawn failed"
            && field("last exit code")?.hasPrefix("78:") == true
    }
    var summary: String {
        guard readable else { return "无法读取系统后台启动状态；不自动重建注册" }
        return "launchd：\(field("job state") ?? field("state") ?? "未知")；PID：\(pid ?? "无")；注册构建：\(build)；退出码：\(field("last exit code") ?? "未知")"
    }
    /// Run only on a worker queue. Output is drained while launchctl runs.
    static func inspect() -> Self {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/" + BatteryControlIdentifiers.helperID]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return Self(output: error.localizedDescription, readable: false) }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5)
        timer.setEventHandler { if process.isRunning { process.terminate() } }
        timer.resume()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timer.cancel()
        return Self(output: String(decoding: data, as: UTF8.self), readable: process.terminationStatus == 0)
    }
}
