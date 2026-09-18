// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum BatteryCommand: String, Codable { case automatic, pause, discharge, full }

struct BatteryControlConfiguration: Codable, Equatable {
    var allowSystemChargeLimit: Bool?
    var enabled = false
    var limit = 80
    var resumeMargin = 5
    var sleepPolicy = "limit"
    var protectTemperature = true
    var temperatureLimit = 40
    var dischargeAboveLimit = false
    var preventSleepDischarging = false
    var preventSleepCharging = false
    var greenLED = false
    var blinkLED = false

    var isValid: Bool {
        (50...100).contains(limit) && (3...10).contains(resumeMargin)
        && (35...45).contains(temperatureLimit)
        && ["limit", "automatic"].contains(sleepPolicy)
    }
}

struct BatteryControlInput {
    var percent: Int
    var external: Bool
    var charging: Bool
    var temperature: Double?
    var lidClosed: Bool
}

/// Shared, deterministic policy. Overrides never bypass thermal/sleep safety.
struct BatteryControlPolicy {
    private(set) var pausedAtLimit = false
    private(set) var overheated = false
    private var previousLimit: Int?
    var override: BatteryCommand = .automatic

    mutating func evaluate(_ input: BatteryControlInput, config: BatteryControlConfiguration,
                           sleeping: Bool = false) -> BatteryCommand {
        guard (0...100).contains(input.percent) else { return .automatic }
        if !input.external {
            override = .automatic
            pausedAtLimit = false
            return .automatic
        }
        let active = config.enabled || override != .automatic
        guard active else { pausedAtLimit = false; overheated = false; return .automatic }
        if previousLimit != config.limit {
            pausedAtLimit = input.percent >= config.limit
            previousLimit = config.limit
        }
        // End overrides even if thermal protection wins the returned command.
        if override == .discharge, sleeping || input.percent <= config.limit { override = .automatic }
        if override == .full, input.percent >= 100 { override = .automatic }
        if config.protectTemperature {
            if let temperature = input.temperature, temperature.isFinite, (0...80).contains(temperature) {
                if temperature >= Double(config.temperatureLimit) { overheated = true }
                else if temperature <= Double(config.temperatureLimit - 3) { overheated = false }
            } else {
                // Unknown temperature must not silently disable an enabled protection.
                overheated = true
            }
        } else { overheated = false }
        if overheated { return .pause }
        if sleeping {
            return config.sleepPolicy == "automatic" ? .automatic : .pause
        }
        if override == .pause { return .pause }
        if override == .full { return .automatic }
        if override == .discharge { return .discharge }
        guard config.enabled else { return .automatic }
        if input.percent >= config.limit { pausedAtLimit = true }
        if input.percent <= config.limit - config.resumeMargin { pausedAtLimit = false }
        if config.dischargeAboveLimit, input.percent > config.limit { return .discharge }
        return pausedAtLimit ? .pause : .automatic
    }
}

struct BatteryAutomationRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "新规则"
    var enabled = true
    var weekdays: [Int] = [1, 2, 3, 4, 5, 6, 7] // Calendar weekday: Sunday = 1
    var startMinute = 0
    var endMinute = 0 // Equal means all day.
    var limit = 80
    var latitude: Double?
    var longitude: Double?
    var radius = 500.0

    var isValid: Bool {
        (50...100).contains(limit) && (0..<1440).contains(startMinute)
        && (0..<1440).contains(endMinute) && !weekdays.isEmpty
        && weekdays.allSatisfy { (1...7).contains($0) }
        && radius.isFinite && (100...10000).contains(radius)
        && ((latitude == nil && longitude == nil)
            || (latitude.map { $0.isFinite && (-90...90).contains($0) } == true
                && longitude.map { $0.isFinite && (-180...180).contains($0) } == true))
    }

    func matches(at date: Date, calendar: Calendar = .current, location: BatteryRuleLocation?) -> Bool {
        guard enabled, isValid else { return false }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        var day = date
        if startMinute < endMinute {
            guard minute >= startMinute && minute < endMinute else { return false }
        } else if startMinute > endMinute {
            guard minute >= startMinute || minute < endMinute else { return false }
            if minute < endMinute { day = calendar.date(byAdding: .day, value: -1, to: date) ?? date }
        }
        guard weekdays.contains(calendar.component(.weekday, from: day)) else { return false }
        if let latitude, let longitude {
            guard let location, location.accuracy >= 0, location.accuracy <= radius,
                  abs(date.timeIntervalSince(location.date)) <= 300 else { return false }
            let r = Double.pi / 180
            let dlat = (location.latitude - latitude) * r
            let dlon = (location.longitude - longitude) * r
            let a = pow(sin(dlat / 2), 2) + cos(latitude * r) * cos(location.latitude * r) * pow(sin(dlon / 2), 2)
            let distance = 6371000 * 2 * asin(sqrt(min(1, max(0, a))))
            guard distance + location.accuracy <= radius else { return false }
        }
        return true
    }
}

struct BatteryRuleLocation {
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var date: Date
}
