#!/bin/sh
# Runs `swift test` with a toolchain that works on a Command-Line-Tools-only machine.
#
#   Scripts/test.sh [--scratch-path DIR] [--filter NAME] [other swift-test arguments]
#
# Two things can go wrong with a bare `swift test`:
#  * xcode-select may point at an Xcode that is absent or whose license was never accepted;
#    then we fall back to the Command Line Tools.
#  * With the Command Line Tools, SwiftPM does not pass the directory holding the Swift Testing
#    macro plugin to the compiler ("plugin for module 'TestingMacros' not found").
set -eu
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools
if ! swift --version >/dev/null 2>&1 && [ -x "$CLT/usr/bin/swift" ]; then
    export DEVELOPER_DIR="$CLT"
fi

developer_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
plugins="$developer_dir/usr/lib/swift/host/plugins/testing"
if [ -d "$plugins" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
