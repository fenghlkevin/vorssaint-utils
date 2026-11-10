#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
worker_test_dir="$(mktemp -d /private/tmp/vorssaint-worker-tests.XXXXXX)"
trap 'rm -rf "$worker_test_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/vorssaint-traffic-module-cache}"
swiftc Sources/Vorssaint/Services/Metrics/AppTrafficWorker.swift Sources/Vorssaint/Services/Metrics/NetworkProcessSupport.swift Sources/Vorssaint/Services/BoundedProcessRunner.swift Tests/Traffic/TrafficWorkerHarness.swift -o "$worker_test_dir/harness"
python3 Tools/test-traffic-worker.py "$worker_test_dir/harness"
