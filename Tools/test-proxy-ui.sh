#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
proxy_ui=/private/tmp/vorssaint-proxy-ui
mkdir -p "$proxy_ui"
bash Tools/build-proxy-yaml.sh "$proxy_ui/yaml"
clang -c Sources/ProxyTunnelBridge/ProxyTunnelBridge.c -I Sources/ProxyTunnelBridge/include -mmacosx-version-min=14.0 -o "$proxy_ui/tun.o"
swiftc -target arm64-apple-macos14.0 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk -Xfrontend -interface-compiler-version -Xfrontend 6.3.2 \
    -I Sources/ProxyYAML/include "$proxy_ui/yaml/libProxyYAML.a" -I Sources/ProxyTunnelBridge/include "$proxy_ui/tun.o" \
    Sources/Vorssaint/Services/Proxy/*.swift Tests/ProxyServiceTestStubs.swift \
    Sources/Vorssaint/UI/Proxy/ProxyActivityViews.swift Sources/Vorssaint/UI/Proxy/ProxyStructuredEditor.swift Sources/Vorssaint/UI/Proxy/ProxyPanelView.swift Sources/Vorssaint/UI/Proxy/ProxyBrandIcon.swift Sources/Vorssaint/UI/Proxy/ProxyDelayBadge.swift Sources/Vorssaint/UI/Proxy/ProxyVisibilityProbe.swift \
    Tests/ProxyUIFixture.swift -o "$proxy_ui/render"
"$proxy_ui/render" "$proxy_ui" "$PWD/Resources/ProxyCore/mihomo-darwin-arm64"
