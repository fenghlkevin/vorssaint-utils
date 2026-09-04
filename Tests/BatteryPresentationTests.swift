import Foundation

@main
struct BatteryPresentationTests {
    static func main() {
        var policy = BatteryLowAlertPolicy()
        precondition(!policy.shouldNotify(percent: 21, discharging: true, enabled: true, threshold: 20))
        precondition(policy.shouldNotify(percent: 20, discharging: true, enabled: true, threshold: 20))
        precondition(!policy.shouldNotify(percent: 19, discharging: true, enabled: true, threshold: 20))
        precondition(!policy.shouldNotify(percent: nil, discharging: true, enabled: true, threshold: 20))
        precondition(!policy.shouldNotify(percent: 19, discharging: true, enabled: true, threshold: 20))
        precondition(!policy.shouldNotify(percent: 20, discharging: false, enabled: true, threshold: 20))
        precondition(policy.shouldNotify(percent: 19, discharging: true, enabled: true, threshold: 20))
        precondition(!policy.shouldNotify(percent: 25, discharging: true, enabled: true, threshold: 20))
        precondition(policy.shouldNotify(percent: 20, discharging: true, enabled: true, threshold: 20))
        precondition(!policy.shouldNotify(percent: 5, discharging: true, enabled: false, threshold: 20))
        precondition(!policy.shouldNotify(percent: -1, discharging: true, enabled: true, threshold: 20))
        precondition(!policy.shouldNotify(percent: 101, discharging: true, enabled: true, threshold: 20))
        precondition(policy.shouldNotify(percent: 5, discharging: true, enabled: true, threshold: -999))

        var hidden = ""
        for field in BatteryMenuField.allCases {
            precondition(field.isVisible(hidden: hidden))
            hidden = field.settingVisible(false, hidden: hidden)
            precondition(!field.isVisible(hidden: hidden))
        }
        for field in BatteryMenuField.allCases { hidden = field.settingVisible(true, hidden: hidden) }
        precondition(hidden.isEmpty)
        print("Battery presentation: visibility and notification threshold tests passed")
    }
}
