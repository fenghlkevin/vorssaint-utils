import Foundation

@main
struct PowerDisplayPolicyTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            precondition(condition, message)
        }
        var profile = PowerDisplayProfile()
        func decision(external: Bool = false, locked: Bool = false,
                      temporary: PowerIdleMode? = nil, low: Bool = false,
                      suspended: Bool = false) -> PowerDisplayDecision {
            PowerDisplayDecision.resolve(profile: profile, external: external, locked: locked,
                temporary: temporary, lowBattery: low, suspended: suspended)
        }
        check(decision().mode == .system, "fresh installation follows the system")
        profile.closedLid = true
        check(!decision().closedLid, "no external display must not disable lid sleep")
        check(decision(external: true).closedLid, "external-only closed-lid work is supported")
        profile.idle = .awake
        profile.external = .bright
        check(decision().mode == .awake, "internal-only uses source idle policy")
        check(decision(external: true).mode == .bright, "external policy overrides source idle")
        check(decision(external: true, temporary: .system).mode == .system, "manual System overrides automatic Bright")
        check(decision(locked: true, temporary: .bright).mode == .awake, "locking releases display assertion")
        profile.locked = .system
        check(!decision(external: true, locked: true).closedLid, "locked System releases closed-lid prevention")
        check(decision(external: true, locked: true).mode == .system, "locked System releases idle prevention")
        profile.locked = nil
        check(decision(external: true, locked: true).mode == .bright, "explicit preserve-on-lock stays bright")
        for mode in PowerIdleMode.allCases {
            for external in [false, true] {
                for locked in [false, true] {
                    check(decision(external: external, locked: locked, temporary: mode, low: true)
                        == PowerDisplayDecision(mode: .system, closedLid: false), "low battery wins every policy")
                    check(decision(external: external, locked: locked, temporary: mode, suspended: true)
                        == PowerDisplayDecision(mode: .system, closedLid: false), "manual sleep wins every policy")
                }
            }
        }
        let suite = "PowerDisplayPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "clamshellPreferred")
        check(!PowerDisplayProfile.read(onBattery: false, defaults: defaults).closedLid,
              "an old manual lid preference never starts a new automatic session")
        defaults.set(true, forKey: "keepAwakeConnectedToPower")
        defaults.set(true, forKey: "keepAwakeAllowDisplaySleep")
        check(PowerDisplayProfile.read(onBattery: false, defaults: defaults).idle == .awake, "migrate AC automation")
        check(PowerDisplayProfile.read(onBattery: false, defaults: defaults).closedLid,
              "existing automatic closed-lid preference is preserved")
        check(PowerDisplayProfile.read(onBattery: true, defaults: defaults).idle == .system, "AC automation never leaks into battery")
        defaults.set(true, forKey: "keepAwakeExternalDisplay")
        check(PowerDisplayProfile.read(onBattery: true, defaults: defaults).external == .awake, "migrate external automation")
        profile.idle = .bright
        profile.save(onBattery: true, defaults: defaults)
        check(PowerDisplayProfile.read(onBattery: true, defaults: defaults) == profile, "profile round trip")
        check(PowerDisplayProfile.read(onBattery: false, defaults: defaults).idle == .awake, "battery and AC store independently")
        defaults.set(Data("invalid".utf8), forKey: PowerDisplayProfile.key(onBattery: true))
        check(PowerDisplayProfile.read(onBattery: true, defaults: defaults).idle == .system, "corrupt profile falls back safely")
        print("Power and display policy: \(count) checks passed")
    }
}
