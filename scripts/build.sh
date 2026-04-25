#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Command Line Tools toolchain needs these to find libc++ and swift-testing's
# C++ sources. Safe to export unconditionally even with full Xcode.
export SDKROOT="$(xcrun --show-sdk-path)"
export CPLUS_INCLUDE_PATH="$SDKROOT/usr/include/c++/v1:$SDKROOT/usr/include${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"
export CPATH="$SDKROOT/usr/include${CPATH:+:$CPATH}"

swift build -c release

BUNDLER="$(command -v swift-bundler || echo "$HOME/.mint/bin/swift-bundler")"
if [ ! -x "$BUNDLER" ]; then
    echo "swift-bundler not found. Install with: mint install stackotter/swift-bundler@main"
    exit 1
fi

"$BUNDLER" bundle -p macOS -c release

APP=".build/bundler/apps/CliBuddy/CliBuddy.app"
if [ ! -d "$APP" ]; then
    echo "Build succeeded but .app not found at $APP"
    exit 1
fi

echo ""
echo "Built: $APP"
du -sh "$APP" | sed 's/^/  size: /'

ZIP="CliBuddy.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
echo "Zipped: $ZIP"
du -sh "$ZIP" | sed 's/^/  size: /'
