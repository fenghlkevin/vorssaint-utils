// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

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
app.run()
