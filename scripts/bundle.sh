#!/usr/bin/env bash
# Build a release PranaBar.app in ./build, ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/PranaBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/PranaBar" "$APP/Contents/MacOS/PranaBar"
cp "Support/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Install with: cp -R $APP /Applications/"
