#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
# Service wiring regression: the standalone flow tests cannot catch a guard
# accidentally inserted ahead of the locked-session return evaluation.
python3 - <<'PYTEST'
from pathlib import Path
source = Path("Sources/Vorssaint/Services/AwayLock/AwayLockService.swift").read_text()
evaluate = source.split("private func evaluate(", 1)[1].split("wakeOnConfirmedReturn(now: now)", 1)[0]
assert "currentSessionLocked()" not in evaluate, "Locked sessions must reach return detection"
request = source.split("private func performAutomaticLockRequest()", 1)[1].split("isConfirmingLock = true", 1)[0]
assert "currentSessionLocked() == false" in request, "Manual locks must not grant return-unlock eligibility"
print("away-lock: locked-session return routing regression passed")
PYTEST
away_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/vorssaint-away-lock-tests.XXXXXX")
trap 'rm -rf "$away_test_dir"' EXIT
away_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
away_sdk_flags=()
if [[ -z "${DEVELOPER_DIR:-}" && -d "$away_sdk" ]]; then
    away_sdk_flags=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
else
    away_sdk=$(xcrun --show-sdk-path)
fi
swiftc -Onone -sdk "$away_sdk" "${away_sdk_flags[@]}" \
    -module-cache-path "$away_test_dir/modules" \
    Sources/Vorssaint/Services/AwayLock/AwayLockScreenControl.swift \
    Sources/Vorssaint/Services/AwayLock/AwayLockSupport.swift \
    Sources/Vorssaint/Services/AwayLock/AwayLockReturnWake.swift \
    Sources/Vorssaint/Services/AwayLock/AwayLockAutoUnlock.swift \
    Sources/Vorssaint/Services/AwayLock/AwayLockPassword.swift \
    Tests/AwayLockScreenControlTests.swift -o "$away_test_dir/tests"
"$away_test_dir/tests"
