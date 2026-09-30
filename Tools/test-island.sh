#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
island_test_root=$(mktemp -d /private/tmp/vorssaint-island-tests.XXXXXX)
trap 'rm -rf "$island_test_root"' EXIT
island_sources=Sources/Vorssaint/Services/DynamicIsland
island_flags=(-module-cache-path "$island_test_root/cache")
swiftc "${island_flags[@]}" "$island_sources/IslandMemoService.swift" Tests/IslandMemoServiceTests.swift -o "$island_test_root/memos"
"$island_test_root/memos"
swiftc "${island_flags[@]}" "$island_sources/IslandTimerClock.swift" Tests/IslandTimerClockTests.swift -o "$island_test_root/timer"
swiftc "${island_flags[@]}" "$island_sources/IslandTimerClock.swift" "$island_sources/TimeReminderService.swift" Tests/IslandTimerServiceTests.swift -o "$island_test_root/timer-service"
"$island_test_root/timer-service"
"$island_test_root/timer"
swiftc "${island_flags[@]}" "$island_sources/IslandSessionPresentation.swift" Tests/IslandSessionPresentationTests.swift -o "$island_test_root/presentation"
"$island_test_root/presentation"
swiftc "${island_flags[@]}" "$island_sources/CodexIncrementalLog.swift" Tests/CodexIncrementalLogTests.swift -o "$island_test_root/logs"
"$island_test_root/logs"
swiftc "${island_flags[@]}" "$island_sources/CodexHookSupport.swift" "$island_sources/CodexIncrementalLog.swift" "$island_sources/IslandPhonePushSupport.swift" Tests/IslandCodexIntegrationTests.swift -o "$island_test_root/protocols"
"$island_test_root/protocols"
swiftc "${island_flags[@]}" -D VORSSAINT_TESTING "$island_sources/CodexIslandService.swift" "$island_sources/CodexHookSupport.swift" "$island_sources/CodexIncrementalLog.swift" "$island_sources/IslandSessionPresentation.swift" "$island_sources/IslandPhonePushSupport.swift" Tests/CodexHookBridgeHarness.swift -o "$island_test_root/bridge"
python3 Tests/CodexHookBridgeIntegration.py "$island_test_root/bridge"
