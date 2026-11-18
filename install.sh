#!/bin/zsh
# Installs the latest ReTerm release into ~/Applications and starts it.
#   curl -fsSL https://raw.githubusercontent.com/wangmengjames/ReTerm/main/install.sh | zsh
set -euo pipefail

URL="https://github.com/wangmengjames/ReTerm/releases/latest/download/ReTerm.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading ReTerm..."
curl -fsSL "$URL" -o "$TMP/ReTerm.zip"
ditto -x -k "$TMP/ReTerm.zip" "$TMP"
codesign --verify --deep --strict "$TMP/ReTerm.app"

mkdir -p "$HOME/Applications"
pkill -f "$HOME/Applications/ReTerm.app/Contents/MacOS/ReTerm" 2>/dev/null || true
rm -rf "$HOME/Applications/ReTerm.app"
ditto "$TMP/ReTerm.app" "$HOME/Applications/ReTerm.app"
open "$HOME/Applications/ReTerm.app"
echo "ReTerm is installed in ~/Applications and running. Look for its icon in the menu bar."
