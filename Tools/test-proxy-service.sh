#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
proxy_tests="$(mktemp -d /private/tmp/vorssaint-proxy-service.XXXXXX)"
proxy_fixture_pid=""
cleanup() { if [[ -n "$proxy_fixture_pid" ]]; then kill "$proxy_fixture_pid" 2>/dev/null || true; wait "$proxy_fixture_pid" 2>/dev/null || true; fi; rm -rf "$proxy_tests"; }
trap cleanup EXIT
bash Tools/prepare-proxy-core.sh
bash Tools/build-proxy-yaml.sh "$proxy_tests/yaml"
clang -mmacosx-version-min=14.0 -c Sources/ProxyTunnelBridge/ProxyTunnelBridge.c -I Sources/ProxyTunnelBridge/include -o "$proxy_tests/tun.o"
swiftc -I Sources/ProxyTunnelBridge/include "$proxy_tests/tun.o" -I Sources/ProxyYAML/include "$proxy_tests/yaml/libProxyYAML.a" Sources/Vorssaint/Services/Proxy/{ProxyWire,ProxySystemProxy,ProxySystemClient,ProxyTunnelClient,ProxyTunnelXPC,ProxyTunnelPolicy,ProxySupport,ProxyStorage,ProxyCore}.swift Sources/ProxyGuardian/main.swift -o "$proxy_tests/guardian"
swiftc -I Sources/ProxyYAML/include -I Sources/ProxyTunnelBridge/include "$proxy_tests/yaml/libProxyYAML.a" "$proxy_tests/tun.o" Sources/Vorssaint/Services/Proxy/*.swift Tests/ProxyServiceTestStubs.swift Tests/ProxyServiceIntegration.swift -o "$proxy_tests/test"
python3 Tests/ProxyTrafficFixture.py > "$proxy_tests/fixture.log" 2>&1 &
proxy_fixture_pid=$!
for attempt in {1..30}; do
    if rg -q '^ready$' "$proxy_tests/fixture.log"; then break; fi
    if ! kill -0 "$proxy_fixture_pid" 2>/dev/null; then cat "$proxy_tests/fixture.log"; exit 1; fi
    sleep 0.1
done
rg -q '^ready$' "$proxy_tests/fixture.log"
"$proxy_tests/test" "$proxy_tests/state" "$PWD/Resources/ProxyCore/mihomo-darwin-arm64" "$proxy_tests/guardian"
