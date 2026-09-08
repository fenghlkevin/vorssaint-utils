import Foundation

@main enum BatteryLaunchDiagnosisTests {
    static func main() {
        let failed = "job state = spawn failed\nlast exit code = 78: EX_CONFIG\nparent bundle version = 123"
        precondition(BatteryLaunchDiagnosis(output: failed, readable: true).failedWithoutProcess)
        precondition(!BatteryLaunchDiagnosis(output: failed + "\npid = 42", readable: true).failedWithoutProcess)
        precondition(!BatteryLaunchDiagnosis(output: failed, readable: false).failedWithoutProcess)
        precondition(!BatteryLaunchDiagnosis(output: "state = running", readable: true).failedWithoutProcess)
        precondition(!BatteryLaunchDiagnosis(output: "job state = spawn failed\nlast exit code = 9", readable: true).failedWithoutProcess)
        precondition(BatteryLaunchDiagnosis(output: failed, readable: true).build == "123")
        print("Battery launch diagnosis: failed, running, unreadable and unknown states passed")
    }
}
