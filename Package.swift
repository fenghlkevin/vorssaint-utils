// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import PackageDescription

let package = Package(
    name: "Vorssaint",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ProxyTunnelBridge", path: "Sources/ProxyTunnelBridge", publicHeadersPath: "include"),
        .target(name: "ProxyYAML", path: "Sources/ProxyYAML", publicHeadersPath: "include", cSettings: [.headerSearchPath("libyaml"), .define("HAVE_CONFIG_H")]),
        .target(
            name: "MenuBarNativeBridge",
            path: "Sources/MenuBarNativeBridge",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .systemLibrary(
            name: "VMStatisticsCompat",
            path: "Sources/VMStatisticsCompat"
        ),
        .executableTarget(
            name: "Vorssaint",
            dependencies: ["VMStatisticsCompat", "MenuBarNativeBridge", "ProxyYAML", "ProxyTunnelBridge"],
            path: "Sources/Vorssaint"
        )
    ]
)
