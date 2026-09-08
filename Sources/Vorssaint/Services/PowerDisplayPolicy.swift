import Foundation

enum PowerIdleMode: String, CaseIterable, Codable {
    case system, awake, bright
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .awake: return "运行可熄屏"
        case .bright: return "屏幕常亮"
        }
    }
    var icon: String {
        switch self {
        case .system: return "leaf"
        case .awake: return "display"
        case .bright: return "sun.max"
        }
    }
}

struct PowerDisplayProfile: Codable, Equatable {
    var idle: PowerIdleMode = .system
    var external: PowerIdleMode? = nil
    var closedLid = false
    var hideInternal = false
    var locked: PowerIdleMode? = .awake

    static func key(onBattery: Bool) -> String {
        onBattery ? "powerDisplay.battery.v1" : "powerDisplay.power.v1"
    }

    static func read(onBattery: Bool, defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey: key(onBattery: onBattery)),
           let profile = try? JSONDecoder().decode(Self.self, from: data) { return profile }
        // Preserve existing automation choices without enabling new behavior.
        let oldMode: PowerIdleMode = defaults.bool(forKey: "keepAwakeAllowDisplaySleep") ? .awake : .bright
        var profile = Self()
        if !onBattery, defaults.bool(forKey: "keepAwakeConnectedToPower") { profile.idle = oldMode }
        if defaults.bool(forKey: "keepAwakeExternalDisplay") { profile.external = oldMode }
        profile.closedLid = defaults.bool(forKey: "clamshellPreferred")
            && (profile.idle != .system || profile.external != nil)
        return profile
    }

    func save(onBattery: Bool, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key(onBattery: onBattery)) }
    }
}

struct PowerDisplayDecision: Equatable {
    let mode: PowerIdleMode
    let closedLid: Bool

    static func resolve(profile: PowerDisplayProfile, external: Bool, locked: Bool,
                        temporary: PowerIdleMode?, lowBattery: Bool, suspended: Bool) -> Self {
        guard !suspended, !lowBattery else { return Self(mode: .system, closedLid: false) }
        let base = temporary ?? (external ? profile.external ?? profile.idle : profile.idle)
        // Locking cannot accidentally start a new awake session from System mode.
        let mode = locked && base != .system ? profile.locked ?? base : base
        let lid = profile.closedLid && external && !(locked && profile.locked == .system)
        return Self(mode: mode, closedLid: lid)
    }
}
