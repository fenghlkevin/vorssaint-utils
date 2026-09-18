#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
proxy_dir=Resources/ProxyCore
proxy_hash=fae1f37e28ee53fcf5be7a8bb121099db1fe442e44205734ed49c62579364090
if [[ -f "$proxy_dir/mihomo-darwin-arm64" ]] && [[ "$(shasum -a 256 "$proxy_dir/mihomo-darwin-arm64" | awk '{print $1}')" == "$proxy_hash" ]]; then exit 0; fi
proxy_tmp="$(mktemp -d)"
trap 'rm -rf "$proxy_tmp"' EXIT
curl --fail --location --retry 2 'https://github.com/MetaCubeX/mihomo/releases/download/v1.19.31/mihomo-darwin-arm64-v1.19.31.gz' -o "$proxy_tmp/core.gz"
echo 'd131f44b3deb2a8356f7ac75048ad67a10d53243323951c4f3cda7b672922963  '"$proxy_tmp/core.gz" | shasum -a 256 -c -
gzip -dc "$proxy_tmp/core.gz" > "$proxy_tmp/core"
echo "$proxy_hash  $proxy_tmp/core" | shasum -a 256 -c -
mkdir -p "$proxy_dir"
cp "$proxy_tmp/core" "$proxy_dir/mihomo-darwin-arm64"
chmod 755 "$proxy_dir/mihomo-darwin-arm64"
