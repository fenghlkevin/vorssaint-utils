#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
mkdir -p build/menu-bar-tests
clang -fobjc-arc -target arm64-apple-macosx14.0 -isysroot "$SDK" \
    -I Sources/MenuBarNativeBridge/include \
    -c Sources/MenuBarNativeBridge/MenuBarClientCoreBridge.m \
    -o build/menu-bar-tests/bridge.o
swiftc -Onone -target arm64-apple-macosx14.0 -sdk "$SDK" \
    -Xfrontend -interface-compiler-version -Xfrontend 6.3.2 \
    -I Sources/MenuBarNativeBridge/include -framework Security \
    build/menu-bar-tests/bridge.o Sources/Vorssaint/App/MenuBarNative/*.swift \
    Tests/MenuBarNativeTests.swift -o build/menu-bar-tests/tests
build/menu-bar-tests/tests
