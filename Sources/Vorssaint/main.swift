// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
#if VORSSAINT_DEVELOPMENT
import SwiftUI
#endif

// Enter before Defaults, AppDelegate, windows or startup services are created.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--app-traffic-worker" {
    exit(AppTrafficWorker.run(parentPID: Int32(CommandLine.arguments[2]) ?? 0))
}

if CommandLine.arguments.contains("--hosts-helper-check") || CommandLine.arguments.contains("--hosts-helper-repair") {
    HostsHelperClient.diagnoseAndExit(repair: CommandLine.arguments.contains("--hosts-helper-repair"))
}

if CommandLine.arguments.contains("--battery-install-prepare") {
    BatteryRegistrationRepair.installPhaseAndExit(prepare: true)
}
if CommandLine.arguments.contains("--battery-install-verify") {
    BatteryRegistrationRepair.installPhaseAndExit(prepare: false)
}

if CommandLine.arguments.contains("--vorssaint-codex-hook") {
    CodexHookBridge.runAndExit()
}

if CommandLine.arguments.contains("--export-codex-sounds") {
    let directory = URL(fileURLWithPath: "/private/tmp/vorssaint-codex-sounds", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sounds: [(String, CodexIslandService.SoundKind)] = [
        ("01-session-start.wav", .started),
        ("02-task-complete.wav", .completed),
        ("03-task-error.wav", .failed),
        ("04-approval-needed.wav", .waiting)
    ]
    for (name, kind) in sounds {
        try? CodexIslandService.soundData(kind).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    exit(0)
}

if CommandLine.arguments.contains("--reset-battery-registration") || CommandLine.arguments.contains("--retire-and-repair-battery-registration") {
    BatteryRegistrationRepair.runAndExit()
}

if CommandLine.arguments.contains("--translation-plugin-worker") { exit(1) }
#if VORSSAINT_DEVELOPMENT
// An isolated UI check: no startup services, persistent feature changes or global hotkeys.
if CommandLine.arguments.contains("--translation-preview") {
    Defaults.register()
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments[AppFeature.translation.availabilityKey] = true
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    NSApplication.shared.setActivationPolicy(.regular)
    TranslationService.shared.show()
    NSApplication.shared.run()
    exit(0)
}
#endif
SuperKeyMappingGuard.runIfRequestedAndExit()
Defaults.register()

if CommandLine.arguments.contains("--selftest") {
    SelfTest.runAndExit()
}
if CommandLine.arguments.contains("--sensors") {
    SensorDump.runAndExit()
}
if CommandLine.arguments.contains("--uninstall") {
    Uninstaller.runAndExit()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
#if VORSSAINT_DEVELOPMENT
// A visible, real-service network view for local delivery checks; no settings changed.
var networkPreviewWindow: NSWindow?
if CommandLine.arguments.contains("--network-preview") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Network · Developer Preview"
        window.contentView = NSHostingView(rootView: ScrollView {
            NetworkSection(collapsible: false).padding(16)
        }.frame(minWidth: 390, minHeight: 400))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        networkPreviewWindow = window
    }
}
#endif
app.run()
