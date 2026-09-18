#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
APP="$PWD/build/Live Translation Probe.app"
mkdir -p "$APP/Contents/MacOS" /private/tmp/vorssaint-audio-module-cache
xcrun swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macos26.0 \
  -module-cache-path /private/tmp/vorssaint-audio-module-cache \
  Tools/LiveTranslationProbe/LiveTranslationProbe.swift Tools/LiveTranslationProbe/PreviewSegments.swift -o "$APP/Contents/MacOS/LiveTranslationProbe"
cp Tools/LiveTranslationProbe/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${VORSSAINT_DEV_SIGNING_IDENTITY:-Apple Development: fenghlkevin@gmail.com (5TXLN986F7)}" "$APP"
codesign --verify --strict "$APP"
echo "$APP"
