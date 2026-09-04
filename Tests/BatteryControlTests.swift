// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct BatteryControlTests {
    static func main() {
        var c = BatteryControlConfiguration(); c.enabled = true
        var p = BatteryControlPolicy()
        var i = BatteryControlInput(percent: 80, external: true, charging: true, temperature: 30, lidClosed: false)
        precondition(p.evaluate(i, config: c) == .pause)
        i.charging = false; i.percent = 78
        precondition(p.evaluate(i, config: c) == .pause)
        i.percent = 75
        precondition(p.evaluate(i, config: c) == .automatic, "Resume must work while NOT charging")
        c.resumeMargin = 10; i.percent = 80
        precondition(p.evaluate(i, config: c) == .pause)
        i.percent = 71; precondition(p.evaluate(i, config: c) == .pause)
        i.percent = 70; precondition(p.evaluate(i, config: c) == .automatic)
        i.temperature = 40; precondition(p.evaluate(i, config: c) == .pause)
        p.override = .full
        precondition(p.evaluate(i, config: c) == .pause, "Full must not bypass heat")
        i.temperature = 38; precondition(p.evaluate(i, config: c) == .pause)
        i.temperature = 37; precondition(p.evaluate(i, config: c) == .automatic)
        i.temperature = nil; precondition(p.evaluate(i, config: c) == .pause)
        i.temperature = .nan; precondition(p.evaluate(i, config: c) == .pause)
        i.temperature = 30; i.percent = 100
        precondition(p.evaluate(i, config: c) == .pause && p.override == .automatic)
        i.percent = 90; p.override = .discharge
        precondition(p.evaluate(i, config: c) == .discharge)
        i.percent = 80; precondition(p.evaluate(i, config: c) == .pause && p.override == .automatic)
        i.percent = 90; p.override = .discharge; i.lidClosed = true
        precondition(p.evaluate(i, config: c) == .discharge)
        i.lidClosed = false; p.override = .discharge
        precondition(p.evaluate(i, config: c, sleeping: true) == .pause && p.override == .automatic)
        c.sleepPolicy = "automatic"
        precondition(p.evaluate(i, config: c, sleeping: true) == .automatic)
        i.temperature = 45
        precondition(p.evaluate(i, config: c, sleeping: true) == .pause)
        i.temperature = 30; i.external = false; p.override = .full
        precondition(p.evaluate(i, config: c) == .automatic && p.override == .automatic)
        i.external = true; c.dischargeAboveLimit = true
        precondition(p.evaluate(i, config: c) == .discharge)
        i.lidClosed = true
        precondition(p.evaluate(i, config: c) == .discharge)
        c.enabled = false; precondition(p.evaluate(i, config: c) == .automatic)
        c.limit = 101; precondition(!c.isValid)
        c.limit = 80; c.resumeMargin = -1; precondition(!c.isValid)
        c = BatteryControlConfiguration(); c.enabled = true
        p = BatteryControlPolicy(); i = .init(percent: 85, external: true, charging: false, temperature: 30, lidClosed: false)
        precondition(p.evaluate(i, config: c) == .pause)
        c.limit = 95
        precondition(p.evaluate(i, config: c) == .automatic, "Raising limit must resume charging")
        c.limit = 80; p.override = .discharge; i.temperature = 45
        precondition(p.evaluate(i, config: c, sleeping: true) == .pause && p.override == .automatic)
        testRules()
        print("Battery control: hysteresis, heat, overrides, sleep, discharge and automation tests passed")
    }
    static func testRules() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let format = ISO8601DateFormatter()
        let monday = format.date(from: "2026-08-31T23:00:00Z")!
        let tuesday = format.date(from: "2026-09-01T01:00:00Z")!
        var rule = BatteryAutomationRule()
        rule.weekdays = [2]; rule.startMinute = 22 * 60; rule.endMinute = 2 * 60
        precondition(rule.matches(at: monday, calendar: calendar, location: nil))
        precondition(rule.matches(at: tuesday, calendar: calendar, location: nil))
        precondition(!rule.matches(at: tuesday.addingTimeInterval(3600), calendar: calendar, location: nil))
        precondition(!rule.matches(at: tuesday.addingTimeInterval(86400), calendar: calendar, location: nil))
        rule.startMinute = 0; rule.endMinute = 0; rule.weekdays = [3]
        precondition(rule.matches(at: tuesday, calendar: calendar, location: nil))
        rule.latitude = 30; rule.longitude = 120
        precondition(!rule.matches(at: tuesday, calendar: calendar, location: nil))
        var location = BatteryRuleLocation(latitude: 30, longitude: 120, accuracy: 50, date: tuesday)
        precondition(rule.matches(at: tuesday, calendar: calendar, location: location))
        location.date = tuesday.addingTimeInterval(-301)
        precondition(!rule.matches(at: tuesday, calendar: calendar, location: location))
        location.date = tuesday; location.accuracy = 501
        precondition(!rule.matches(at: tuesday, calendar: calendar, location: location))
        location.accuracy = 50; location.latitude = 31
        precondition(!rule.matches(at: tuesday, calendar: calendar, location: location))
        rule.latitude = 100; precondition(!rule.isValid)
        rule.latitude = 30; rule.longitude = nil; precondition(!rule.isValid)
        rule.longitude = 120; rule.radius = .nan; precondition(!rule.isValid)
        var ordinary = BatteryAutomationRule(); ordinary.startMinute = 9 * 60; ordinary.endMinute = 17 * 60
        precondition(!ordinary.matches(at: monday, calendar: calendar, location: nil))
        let noon = format.date(from: "2026-08-31T12:00:00Z")!
        precondition(ordinary.matches(at: noon, calendar: calendar, location: nil))
        ordinary.enabled = false; precondition(!ordinary.matches(at: noon, calendar: calendar, location: nil))
    }
}
