#!/bin/bash
# Runs a real local core with temporary ports; never changes system proxy settings.
# Optional first argument: local user YAML. Never add real configurations to git.
set -euo pipefail
cd "$(dirname "$0")/.."
proxy_tests="$(mktemp -d /private/tmp/vorssaint-proxy-live.XXXXXX)"
trap 'rm -rf "$proxy_tests"' EXIT
bash Tools/prepare-proxy-core.sh
clang -mmacosx-version-min=14.0 -c Sources/ProxyTunnelBridge/ProxyTunnelBridge.c -I Sources/ProxyTunnelBridge/include -o "$proxy_tests/tun.o"
bash Tools/build-proxy-yaml.sh "$proxy_tests/yaml"
python3 Tests/ProxyGuardianBundlePath.py "$proxy_tests/guardian"

swiftc -I Sources/ProxyTunnelBridge/include "$proxy_tests/tun.o" -I Sources/ProxyYAML/include "$proxy_tests/yaml/libProxyYAML.a" Sources/Vorssaint/Services/Proxy/{ProxyWire,ProxySystemProxy,ProxySystemClient,ProxyTunnelClient,ProxyTunnelXPC,ProxyTunnelPolicy,ProxySupport,ProxyStorage,ProxyCore}.swift Sources/ProxyGuardian/main.swift -o "$proxy_tests/guardian"
swiftc -I Sources/ProxyTunnelBridge/include "$proxy_tests/tun.o" -I Sources/ProxyYAML/include "$proxy_tests/yaml/libProxyYAML.a" \
    Sources/Vorssaint/Services/Proxy/ProxyTunnelPolicy.swift Sources/Vorssaint/Services/Proxy/ProxySupport.swift \
    Sources/Vorssaint/Services/Proxy/ProxyStorage.swift \
    Sources/Vorssaint/Services/Proxy/ProxyCore.swift \
    Sources/Vorssaint/Services/Proxy/ProxyResources.swift \
    Sources/Vorssaint/Services/Proxy/ProxyWire.swift Sources/Vorssaint/Services/Proxy/ProxySystemProxy.swift Sources/Vorssaint/Services/Proxy/ProxyTunnelXPC.swift \
    Sources/Vorssaint/Services/Proxy/ProxyGuardianClient.swift \
    Tests/ProxyCoreIntegration.swift -o "$proxy_tests/integration"
"$proxy_tests/integration" "$proxy_tests/state" "$PWD/Resources/ProxyCore/mihomo-darwin-arm64" "$proxy_tests/guardian" "$@"

python3 Tests/ProxyGuardianLifetime.py "$proxy_tests/lifetime" "$PWD/Resources/ProxyCore/mihomo-darwin-arm64" "$proxy_tests/guardian"

if [[ "${PROXY_TEST_LAUNCHD:-0}" == "1" ]]; then
    python3 Tests/ProxyGuardianLaunchd.py "$proxy_tests/guardian" "$PWD/Resources/ProxyCore/mihomo-darwin-arm64"
fi
