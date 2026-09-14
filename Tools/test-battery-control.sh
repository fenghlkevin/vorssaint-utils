#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d /private/tmp/vorssaint-battery-tests.XXXXXX)"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/vorssaint-module-cache}"
swiftc Sources/Vorssaint/Services/Battery/BatteryTelemetryTracker.swift Tests/BatteryTelemetryTests.swift -o "$test_dir/telemetry"
"$test_dir/telemetry"
swiftc Sources/Vorssaint/Services/Battery/BatteryDiagnosticSnapshot.swift Tests/BatteryDiagnosticSnapshotTests.swift -o "$test_dir/snapshot"
"$test_dir/snapshot"
shared=(
    Sources/Vorssaint/Services/Metrics/TemperatureSensorSelector.swift
    Sources/Vorssaint/Services/FanControl/FanControlSupport.swift
    Sources/Vorssaint/Services/SystemMonitor/SMCClient.swift
    Sources/Vorssaint/Services/Battery/BatteryControlPolicy.swift
    Sources/Vorssaint/Services/Battery/BatteryMaintenanceSafety.swift
    Sources/Vorssaint/Services/Battery/BatteryControlHardware.swift
)
swiftc Sources/Vorssaint/Services/Battery/BatteryControlPolicy.swift Sources/Vorssaint/Services/Battery/BatteryMaintenanceSafety.swift Tests/BatteryMaintenanceSafetyTests.swift -o "$test_dir/maintenance"
"$test_dir/maintenance"
swiftc "${shared[@]}" Sources/Vorssaint/Services/Battery/BatteryControlXPC.swift Sources/Vorssaint/Services/Battery/BatteryLaunchDiagnosis.swift Tests/BatteryLaunchDiagnosisTests.swift -o "$test_dir/launch"
"$test_dir/launch"
swiftc Sources/Vorssaint/Services/Battery/BatteryPanelLayout.swift Tests/BatteryPanelLayoutTests.swift -o "$test_dir/layout"
"$test_dir/layout"
swiftc Sources/Vorssaint/Services/Battery/BatteryControlPolicy.swift Tests/BatteryControlTests.swift -o "$test_dir/policy"
"$test_dir/policy"
swiftc "${shared[@]}" Tests/BatteryHardwareTests.swift -o "$test_dir/hardware"
"$test_dir/hardware"
swiftc Sources/Vorssaint/Services/Battery/BatteryPresentationSupport.swift Tests/BatteryPresentationTests.swift -o "$test_dir/presentation"
"$test_dir/presentation"
swiftc Sources/Vorssaint/Services/Battery/BatteryPowerFlow.swift Tests/BatteryPowerFlowTests.swift -o "$test_dir/flow"
"$test_dir/flow"
swiftc "${shared[@]}" Sources/Vorssaint/Services/Battery/BatteryControlXPC.swift Sources/Vorssaint/Services/Battery/BatteryLaunchDiagnosis.swift Sources/Vorssaint/Services/BoundedProcessRunner.swift Sources/BatteryControlHelper/main.swift -o "$test_dir/helper"
"$test_dir/helper" --selftest
printf 'Battery test executables: %s\n' "$test_dir"
