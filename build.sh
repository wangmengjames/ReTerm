#!/bin/zsh
# Builds build/ReTerm.app. Pass "install" to also copy it to ~/Applications.
set -euo pipefail
cd "${0:A:h}"

APP="build/ReTerm.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -swift-version 5 -O -o "$APP/Contents/MacOS/ReTerm" Sources/*.swift
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    mkdir -p "$HOME/Applications"
    ditto "$APP" "$HOME/Applications/ReTerm.app"
    echo "Installed to $HOME/Applications/ReTerm.app"
fi
