// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct AwayLockStrings {
    let title: String
    let caption: String
    let enable: String
    let device: String
    let searching: String
    let noDevice: String
    let threshold: String
    let weakDuration: String
    let lossDuration: String
    let grace: String
    let protectInput: String
    let status: String
    let bluetoothUnavailable: String
    let seconds: String

    static var current: AwayLockStrings { strings(for: L10n.shared.language) }

    static func strings(for language: AppLanguage) -> AwayLockStrings {
        switch language {
        case .zhHans, .zhTW, .zhHK:
            return AwayLockStrings(
                title: "离开自动锁定", caption: "蓝牙设备离开后自动锁定 Mac",
                enable: "启用距离监测", device: "目标蓝牙设备", searching: "正在扫描附近设备…",
                noDevice: "尚未发现设备，请让目标设备保持可发现状态。", threshold: "离开阈值",
                weakDuration: "弱信号持续时间", lossDuration: "失联判定时间", grace: "锁定倒计时",
                protectInput: "操作 Mac 时取消锁定", status: "运行状态",
                bluetoothUnavailable: "蓝牙不可用或尚未授权", seconds: "秒")
        default:
            return AwayLockStrings(
                title: "Away Lock", caption: "Lock the Mac when a Bluetooth device moves away",
                enable: "Monitor distance", device: "Target Bluetooth device", searching: "Scanning nearby devices…",
                noDevice: "No devices found yet. Keep the target device discoverable.", threshold: "Away threshold",
                weakDuration: "Weak signal duration", lossDuration: "Signal loss timeout", grace: "Lock countdown",
                protectInput: "Cancel while the Mac is in use", status: "Status",
                bluetoothUnavailable: "Bluetooth is unavailable or not authorized", seconds: "seconds")
        }
    }
}
