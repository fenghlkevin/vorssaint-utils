#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
chain_test_dir="$(mktemp -d /private/tmp/vorssaint-chain-tests.XXXXXX)"
trap 'rm -rf "$chain_test_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/vorssaint-traffic-module-cache}"
swiftc Sources/Vorssaint/Services/NetworkChain/NetworkChainSupport.swift Sources/Vorssaint/Services/NetworkChain/NetworkFlowSupport.swift Tests/Traffic/NetworkChainTests.swift -o "$chain_test_dir/tests"
"$chain_test_dir/tests"
if [[ "${1:-}" == "--live" ]]; then
    swiftc Sources/Vorssaint/Services/NetworkChain/NetworkChainSupport.swift Sources/Vorssaint/Services/NetworkChain/NetworkFlowSupport.swift Sources/Vorssaint/Services/BoundedProcessRunner.swift Tests/Traffic/NetworkChainLiveTests.swift -o "$chain_test_dir/live"
    "$chain_test_dir/live"
fi
