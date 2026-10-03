#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
hosts_tests="$(mktemp -d /private/tmp/vorssaint-hosts-tests.XXXXXX)"
trap 'rm -rf "$hosts_tests"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/vorssaint-module-cache}"
swiftc Sources/Vorssaint/Services/Proxy/ProxyTunnelXPC.swift Sources/Vorssaint/Services/Hosts/HostsSupport.swift Sources/Vorssaint/Services/Hosts/HostsHelperPolicy.swift Sources/Vorssaint/Services/Hosts/HostsSystemWriter.swift Tests/HostsTests.swift -o "$hosts_tests/tests"
"$hosts_tests/tests"
