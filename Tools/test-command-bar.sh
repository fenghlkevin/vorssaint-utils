#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/vorssaint-command-bar-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
swiftc -Onone -target arm64-apple-macosx14.0 -module-cache-path "$test_dir/modules" \
    Sources/Vorssaint/Services/CommandBar/CommandBarSupport.swift \
    Sources/Vorssaint/Services/CommandBar/CommandBarPreferences.swift \
    Sources/Vorssaint/Services/CommandBar/CommandBarJSONDocument.swift \
    Sources/Vorssaint/Services/CommandBar/CommandBarDeveloperSupport.swift \
    Sources/Vorssaint/Services/CommandBar/CommandBarBuiltinPreferences.swift \
    Sources/Vorssaint/Services/CommandBar/CommandBarPortSupport.swift \
    Sources/Vorssaint/Services/KillProcess/KillProcessSupport.swift \
    Sources/Vorssaint/Services/BoundedProcessRunner.swift \
    Tests/CommandBarDeveloperTests.swift -o "$test_dir/tests"
# --integration binds loopback TCP/UDP sockets and kills only a spawned test child.
"$test_dir/tests" "$@"
