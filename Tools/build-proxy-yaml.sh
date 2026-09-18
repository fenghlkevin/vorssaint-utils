#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
proxy_output="${1:?output directory required}"
mkdir -p "$proxy_output"
for source in Sources/ProxyYAML/libyaml/*.c; do
    clang -c "$source" -I Sources/ProxyYAML/libyaml -DHAVE_CONFIG_H -Wno-deprecated-non-prototype -mmacosx-version-min=14.0 -o "$proxy_output/$(basename "${source%.c}").o"
done
clang -fobjc-arc -c Sources/ProxyYAML/ProxyYAML.m -I Sources/ProxyYAML/include -I Sources/ProxyYAML/libyaml -mmacosx-version-min=14.0 -o "$proxy_output/bridge.o"
ar rcs "$proxy_output/libProxyYAML.a" "$proxy_output"/*.o
