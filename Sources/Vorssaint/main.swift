// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

if CommandLine.arguments.contains("--reset-battery-registration") {
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
