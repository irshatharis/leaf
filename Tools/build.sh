#!/bin/zsh
# Builds Leaf for the Mac (Release, ad-hoc signed) and the leaf command, and installs them to /Applications and ~/.local/bin.
# Usage: Tools/build.sh [--no-install]
set -eu
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

xcodebuild -project Notebook.xcodeproj -scheme Notebook -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGN_IDENTITY=- build 2>&1 \
  | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' || true
[[ -d build/Build/Products/Release/Leaf.app ]] || { echo "build failed"; exit 1; }
xcrun swiftc -O -o build/leaf Tools/leaf.swift || { echo "leaf build failed"; exit 1; }

[[ ${1:-} == --no-install ]] && exit 0
pkill -x Leaf 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/Leaf.app
cp -R build/Build/Products/Release/Leaf.app /Applications/
mkdir -p "$HOME/.local/bin"
rm -f "$HOME/.local/bin/leaf"
cp build/leaf "$HOME/.local/bin/leaf"
echo "installed /Applications/Leaf.app and ~/.local/bin/leaf"
