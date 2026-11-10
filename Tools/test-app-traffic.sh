#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
traffic_test_dir="$(mktemp -d /private/tmp/vorssaint-traffic-tests.XXXXXX)"
trap 'rm -rf "$traffic_test_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/vorssaint-traffic-module-cache}"
swiftc Sources/Vorssaint/Services/Metrics/AppTrafficLedger.swift \
    Sources/Vorssaint/Services/Metrics/NetworkProcessSupport.swift \
    Sources/Vorssaint/Services/BoundedProcessRunner.swift \
    Tests/Traffic/AppTrafficTests.swift -o "$traffic_test_dir/tests"
"$traffic_test_dir/tests"
if [[ "${1:-}" == "--live" ]]; then
    swiftc -parse-as-library Sources/Vorssaint/Services/Metrics/NetworkProcessSupport.swift \
        Sources/Vorssaint/Services/BoundedProcessRunner.swift Tests/Traffic/AppTrafficLiveTests.swift -o "$traffic_test_dir/live"
    "$traffic_test_dir/live"
fi
