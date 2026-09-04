import Foundation

@main enum BatteryPowerFlowTests {
    static func main() {
        func flow(_ external: Bool, _ battery: Double?, charging: Bool = false, hasBattery: Bool = true) -> BatteryPowerFlow {
            BatteryPowerFlow(external: external, hasBattery: hasBattery, charging: charging,
                             adapter: 30, battery: battery, system: 20)
        }
        let paused = flow(true, 0)
        precondition(paused.inputs.map(\.kind) == [.adapter] && paused.outputs.map(\.kind) == [.computer])
        precondition(paused.outputs[0].watts == 30)
        let charging = flow(true, 10, charging: true)
        precondition(charging.inputs.map(\.kind) == [.adapter] && charging.outputs.map(\.kind) == [.computer, .battery])
        precondition(charging.outputs[0].watts == 20)
        let unplugged = flow(false, -20)
        precondition(unplugged.inputs.map(\.kind) == [.battery] && unplugged.inputs[0].watts == 20)
        precondition(unplugged.outputs[0].watts == 20)
        let hybrid = flow(true, -10)
        precondition(hybrid.inputs.map(\.kind) == [.adapter, .battery] && hybrid.outputs.map(\.kind) == [.computer])
        precondition(hybrid.outputs[0].watts == 40)
        let forced = BatteryPowerFlow(external: false, hasBattery: true, charging: false,
                                      adapter: 0, battery: -0.0, system: 22.6, forcedDischarge: true)
        precondition(forced.inputs.first?.kind == .battery && forced.inputs.first?.watts == 22.6)
        precondition(forced.outputs.first?.kind == .computer && forced.outputs.first?.watts == 22.6)
        precondition(flow(true, nil, charging: true).outputs.last?.watts == nil)
        precondition(flow(true, nil).note != nil)
        precondition(flow(false, 5, charging: true).note != nil)
        precondition(flow(false, nil, hasBattery: false).inputs.map(\.kind) == [.adapter])
        precondition(flow(true, -0.1).inputs.count == 1)
        precondition(flow(true, .infinity).note != nil)
        precondition(BatteryTemperatureDisplay.celsius(2809) == 28.09)
        precondition(BatteryTemperatureDisplay.celsius(3013) == 30.13)
        precondition(BatteryTemperatureDisplay.celsius(.nan) == nil)
        precondition(BatteryTemperatureDisplay.celsius(-1) == nil)
        print("Battery flow: AC, charging, battery-only, hybrid, unknown, transition and temperature tests passed")
    }
}
