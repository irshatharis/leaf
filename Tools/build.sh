#!/bin/zsh
# Builds Leaf for the Mac (Release, ad-hoc signed) and installs it to /Applications with the leaf CLI.
# Usage: Tools/build.sh [--no-install]
set -eu
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

xcodebuild -project Notebook.xcodeproj -scheme Notebook -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGN_IDENTITY=- build 2>&1 \
  | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' || true
[[ -d build/Build/Products/Release/Leaf.app ]] || { echo "build failed"; exit 1; }

[[ ${1:-} == --no-install ]] && exit 0
pkill -x Leaf 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/Leaf.app
cp -R build/Build/Products/Release/Leaf.app /Applications/
if [[ -f Tools/leaf ]]; then
  mkdir -p "$HOME/.local/bin"
  ln -sf "$PWD/Tools/leaf" "$HOME/.local/bin/leaf"
fi
echo "installed /Applications/Leaf.app"
