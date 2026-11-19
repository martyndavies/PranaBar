#!/usr/bin/env bash
# Run the test suite.
#
# With only the Command Line Tools installed (no Xcode.app), SwiftPM finds
# neither XCTest nor Swift Testing's Testing.framework on its own: it passes the
# CLT frameworks folder as -I rather than -F. The generated test runner then
# compiles with canImport(Testing) == false, runs nothing, and exits 0. So pass
# the framework search path, and the runtime paths, explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

dev="$(xcode-select -p)"
args=()
if [[ "$dev" == */CommandLineTools ]]; then
  fw="$dev/Library/Developer/Frameworks"
  args+=(
    -Xswiftc -F -Xswiftc "$fw"
    -Xlinker -rpath -Xlinker "$fw"
    -Xlinker -rpath -Xlinker "$dev/Library/Developer/usr/lib"
  )
fi

exec swift test ${args[@]+"${args[@]}"} "$@"
