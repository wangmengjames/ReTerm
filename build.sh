#!/bin/zsh
# Builds build/ReTerm.app (universal: Apple silicon + Intel).
#   ./build.sh            build only
#   ./build.sh install    build and copy to ~/Applications
#   ./build.sh release    build and create dist/ReTerm.zip for a GitHub release
set -euo pipefail
cd "${0:A:h}"

APP="build/ReTerm.app"
BIN="$APP/Contents/MacOS/ReTerm"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for arch in arm64 x86_64; do
    swiftc -swift-version 5 -O -target "$arch-apple-macos13.0" -o "build/ReTerm-$arch" Sources/*.swift
done
lipo -create -output "$BIN" build/ReTerm-arm64 build/ReTerm-x86_64
rm -f build/ReTerm-arm64 build/ReTerm-x86_64
codesign --force --sign - "$APP"
echo "Built $APP"

case "${1:-}" in
    install)
        mkdir -p "$HOME/Applications"
        rm -rf "$HOME/Applications/ReTerm.app"
        ditto "$APP" "$HOME/Applications/ReTerm.app"
        echo "Installed to $HOME/Applications/ReTerm.app"
        ;;
    release)
        mkdir -p dist
        rm -f dist/ReTerm.zip
        ditto -c -k --keepParent "$APP" dist/ReTerm.zip
        echo "Created dist/ReTerm.zip"
        ;;
esac
