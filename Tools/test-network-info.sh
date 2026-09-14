#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
network_test_dir="$(mktemp -d /private/tmp/vorssaint-network-tests.XXXXXX)"
trap 'rm -rf "$network_test_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/vorssaint-module-cache}"
swiftc Sources/Vorssaint/Services/NetworkInfo/NetworkInfoSupport.swift Sources/Vorssaint/Services/NetworkInfo/NetworkInfoService.swift Sources/Vorssaint/Services/NetworkInfo/NetworkInfoHistory.swift Tests/NetworkInfoTests.swift -o "$network_test_dir/network-info"
"$network_test_dir/network-info" "$@"
swiftc Sources/Vorssaint/Services/CommandBar/CommandBarSupport.swift Sources/Vorssaint/Services/CommandBar/CommandBarPreferences.swift Tests/CommandBarPreferencesTests.swift -o "$network_test_dir/preferences"
"$network_test_dir/preferences"
