// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class CommandBarPortProvider {
    var onResult: (() -> Void)?
    private var generation = UUID()
    private var pending: DispatchWorkItem?
    private var port: Int?
    private var processes: [CommandBarPortProcess] = []
    private var busy = false
    private var message: String?
    private var failure: CommandBarPortError?
    private let queue = DispatchQueue(label: "Vorssaint.commandBar.ports", qos: .userInitiated)
    private let t = CommandBarDeveloperText.text

    func reset() {
        pending?.cancel()
        pending = nil
        generation = UUID()
        port = nil
        processes = []
        busy = false
        message = nil
        failure = nil
    }

    /// Nil leaves ordinary search alone. Explicit port queries own the list.
    func rows(for query: String) -> [CommandBarEntry]? {
        switch CommandBarPortSupport.query(query) {
        case .unrelated:
            if port != nil { reset() }
            return nil
        case .needsPort, .invalid:
            reset()
            let trigger = CommandBarBuiltinSettings.trigger(.port)
            return [status(t("输入 \(trigger) 端口号，例如 \(trigger) 8080", "Enter a port, for example \(trigger) 8080"),
                           detail: t("端口范围 1–65535；查询 TCP 监听和 UDP 本地绑定", "Ports 1–65535; TCP listeners and local UDP bindings"))]
        case .port(let value):
            if port != value { reset(); port = value; schedule(port: value) }
            if busy {
                return [status(message ?? t("正在查询端口 \(value)…", "Looking up port \(value)…"), detail: "TCP / UDP")]
            }
            var rows: [CommandBarEntry] = []
            if let failure {
                rows.append(status(errorText(failure), detail: "port \(value)"))
            } else {
                let report = diagnostic(port: value)
                rows.append(CommandBarEntry(id: "port.report", title: t("复制端口 \(value) 的诊断信息", "Copy diagnostics for port \(value)"),
                    subtitle: message ?? (processes.isEmpty
                        ? t("未发现当前用户可见的 TCP 监听 / UDP 绑定", "No TCP listeners / UDP bindings visible to this user")
                        : t("\(processes.count) 个进程占用；下方可强制结束", "\(processes.count) owning processes; force quit below")),
                    icon: .symbol("network"), countsUsage: false) { _ in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    })
                for process in processes {
                    let title = "\(process.name) · PID \(process.pid)"
                    let endpoints = process.sockets.map { "\($0.transport) \($0.address)" }.joined(separator: ", ")
                    rows.append(CommandBarEntry(id: "port.process.\(process.pid)", title: title,
                        subtitle: "\(endpoints) · \(process.path.isEmpty ? t("路径不可用", "Path unavailable") : process.path)",
                        icon: .symbol("terminal"), countsUsage: false,
                        revealPath: process.path.isEmpty ? nil : process.path) { _ in
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(title)\n\(endpoints)\n\(process.path)", forType: .string)
                        })
                    if !process.isProtected {
                        rows.append(CommandBarEntry(id: "port.force.\(process.pid)",
                            title: t("强制结束 \(title)", "Force quit \(title)"),
                            subtitle: t("释放端口 \(value) · SIGKILL", "Release port \(value) · SIGKILL"),
                            icon: .symbol("exclamationmark.octagon"),
                            confirmationPrompt: t("强制结束 \(title)？未保存的数据将丢失。再次回车确认。", "Force quit \(title)? Unsaved data will be lost. Press Return again to confirm."),
                            countsUsage: false, keepsBarOpen: true) { [weak self] _ in
                                self?.forceKill(process, port: value)
                            })
                    } else {
                        rows.append(status(t("此进程受保护或无法核实身份", "Protected process or unverifiable identity"),
                            detail: title, id: "port.protected.\(process.pid)"))
                    }
                }
            }
            rows.append(CommandBarEntry(id: "port.refresh", title: t("刷新端口 \(value)", "Refresh port \(value)"),
                subtitle: "TCP / UDP", icon: .symbol("arrow.clockwise"), countsUsage: false,
                keepsBarOpen: true) { [weak self] _ in
                    self?.schedule(port: value)
                    self?.onResult?()
                })
            return rows
        }
    }

    private func status(_ title: String, detail: String, id: String = "port.status") -> CommandBarEntry {
        CommandBarEntry(id: id, title: title, subtitle: detail, icon: .symbol("info.circle"),
                        countsUsage: false, keepsBarOpen: true) { _ in }
    }

    private func schedule(port: Int) {
        pending?.cancel()
        generation = UUID()
        busy = true
        failure = nil
        message = nil
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.queue.async { [weak self] in
                let result = Result { try CommandBarPortSupport.scan(port: port) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.accept(result)
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func accept(_ result: Result<[CommandBarPortProcess], Error>) {
        busy = false
        switch result {
        case .success(let processes): self.processes = processes; failure = nil
        case .failure(let error): processes = []; failure = error as? CommandBarPortError ?? .scanFailed
        }
        onResult?()
    }

    private func forceKill(_ process: CommandBarPortProcess, port: Int) {
        guard CommandBarBuiltinSettings.isEnabled(CommandBarBuiltinTool.port) else { return }
        guard !busy, self.port == port else { return }
        busy = true
        generation = UUID()
        let token = generation
        message = t("正在核实并强制结束 PID \(process.pid)…", "Verifying and force quitting PID \(process.pid)…")
        onResult?()
        queue.async { [weak self] in
            let action = Result { try CommandBarPortSupport.forceKill(process, port: port) }
            // Give the kernel a moment to release sockets before the fresh scan.
            if case .success = action { Thread.sleep(forTimeInterval: 0.15) }
            let refreshed = Result { try CommandBarPortSupport.scan(port: port) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                switch action {
                case .success:
                    self.message = self.t("已向 PID \(process.pid) 发送 SIGKILL；端口状态已刷新", "SIGKILL sent to PID \(process.pid); port status refreshed")
                case .failure(let error):
                    self.message = self.errorText(error as? CommandBarPortError ?? .killFailed)
                }
                self.accept(refreshed)
            }
        }
    }

    private func diagnostic(port: Int) -> String {
        var lines = ["Port: \(port)", "Scope: TCP LISTEN / UDP local bindings visible to the current user", "Checked: \(ISO8601DateFormatter().string(from: Date()))"]
        if processes.isEmpty { lines.append("No visible owners found.") }
        for process in processes {
            lines.append("\nPID: \(process.pid)\nProcess: \(process.name)\nPath: \(process.path)")
            lines.append(contentsOf: process.sockets.map { "\($0.transport): \($0.address)" })
        }
        return lines.joined(separator: "\n")
    }

    private func errorText(_ error: CommandBarPortError) -> String {
        switch error {
        case .scanFailed: return t("端口查询失败，无法确认占用情况，请刷新重试", "Port lookup failed; ownership is unknown. Refresh to retry")
        case .timedOut: return t("端口查询超时，请刷新重试", "Port lookup timed out; refresh to retry")
        case .protectedProcess: return t("受保护的进程不能结束", "Protected processes cannot be terminated")
        case .staleProcess: return t("进程已退出、身份变化或不再占用端口；未执行结束操作", "Process exited, changed identity or released the port; nothing was killed")
        case .permissionDenied: return t("当前用户没有结束此进程的权限", "The current user does not have permission to terminate this process")
        case .killFailed: return t("结束进程失败，请刷新后重试", "Failed to terminate the process; refresh and retry")
        }
    }
}
