// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine
import CoreLocation

final class BatteryAutomationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = BatteryAutomationService()
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "batteryManagement.automationEnabled"); updateLocationSampling() }
    }
    @Published var rules: [BatteryAutomationRule] {
        didSet {
            if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "batteryManagement.rules.v1") }
            updateLocationSampling()
        }
    }
    @Published private(set) var locationMessage = "地点规则需要定位权限；不上传位置"
    @Published private(set) var location: BatteryRuleLocation?
    private let manager = CLLocationManager()
    private var sampling = false
    private var captureRequested = false
    private var lastLocationRequest = Date.distantPast
    private override init() {
        enabled = UserDefaults.standard.bool(forKey: "batteryManagement.automationEnabled")
        rules = UserDefaults.standard.data(forKey: "batteryManagement.rules.v1")
            .flatMap { try? JSONDecoder().decode([BatteryAutomationRule].self, from: $0) } ?? []
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
    }
    func matchingRule(at date: Date = Date()) -> BatteryAutomationRule? {
        guard enabled else { return nil }
        return rules.first { $0.matches(at: date, location: location) }
    }
    func requestLocation() {
        captureRequested = true
        manager.requestWhenInUseAuthorization()
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized { manager.requestLocation() }
    }
    func updateLocationSampling() {
        let authorized = manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized
        let needed = enabled && UserDefaults.standard.bool(forKey: DefaultsKey.batteryManagementEnabled)
            && AppFeature.batteryManagement.isAvailable && rules.contains { $0.enabled && $0.latitude != nil } && authorized
        if needed && !sampling { manager.startUpdatingLocation(); sampling = true }
        // A stationary Mac may not receive distance-filtered updates. Refresh
        // the fix periodically so a valid home/office rule does not expire.
        if needed && Date().timeIntervalSince(lastLocationRequest) >= 120 {
            lastLocationRequest = Date()
            manager.requestLocation()
        }
        if !needed && sampling { manager.stopUpdatingLocation(); sampling = false; location = nil }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted: location = nil; locationMessage = "定位未授权：地点规则不匹配；可继续使用时间规则"
        case .authorizedAlways, .authorized:
            locationMessage = "定位已授权，仅在本机匹配地点"
            if captureRequested { manager.requestLocation() }
        default: locationMessage = "地点规则需要定位权限；不上传位置"
        }
        updateLocationSampling()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last, value.horizontalAccuracy >= 0, abs(value.timestamp.timeIntervalSinceNow) <= 300 else { return }
        location = BatteryRuleLocation(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude,
                                       accuracy: value.horizontalAccuracy, date: value.timestamp)
        captureRequested = false
        locationMessage = "位置已更新，精度约 \(Int(value.horizontalAccuracy)) 米"
        BatteryManagementService.shared.refresh()
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        location = nil; captureRequested = false; locationMessage = "定位暂不可用，地点规则不匹配"
    }
}
