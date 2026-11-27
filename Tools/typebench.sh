#!/bin/zsh
# Types into a note of a copy of your notes and reports what each key costs the main thread (DebugRemote typebench).
# Builds Debug (for the debug remote) with Release's optimization, into build-bench, unless --no-build.
# BENCH_APP=<app> measures another bench build.
# Usage: Tools/typebench.sh [--no-build] <folder> <note relative to folder> <caret index> [keys] [runs]
set -eu
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
if [[ ${1:-} == --no-build ]]; then shift; else
  xcodebuild -project Notebook.xcodeproj -scheme Notebook -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath build-bench CODE_SIGN_IDENTITY=- SWIFT_OPTIMIZATION_LEVEL=-O ONLY_ACTIVE_ARCH=YES ENABLE_HARDENED_RUNTIME=NO ENABLE_DEBUG_DYLIB=NO build 2>&1 \
    | grep -E ' error:|BUILD (SUCCEEDED|FAILED)' || true
fi
folder=${1:?folder}; note=${2:?note}; caret=${3:?caret}; keys=${4:-200}; runs=${5:-3}
exe=${BENCH_APP:-build-bench/Build/Products/Debug/Leaf.app}/Contents/MacOS/Leaf
[[ -x $exe ]] || { echo "no bench build"; exit 1; }
ws=$(pgrep -x WindowServer)
# CPU seconds a process has used, less a start value when given.
cpu() { ps -o time= -p $1 | awk -v start=${2:-0} -F'[:.]' '{ printf "%.2f", $1 * 60 + $2 + $3 / 100 - start }'; }
original=$(mktemp)
cp "$folder/$note" "$original"

for i in $(seq $runs); do
  cp "$original" "$folder/$note"
  cmdfile=$(mktemp)
  : > "$cmdfile"
  rm -f "$cmdfile.log"
  "$exe" -NotebookLibrary "$folder" -debugCommandFile "$cmdfile" >/dev/null 2>&1 &
  pid=$!
  sleep 4
  print -l "open $note" "wait 2" "fakekey" "focus" "caret $caret" "wait 1" >> "$cmdfile"
  sleep 4
  app0=$(cpu $pid); ws0=$(cpu $ws)
  echo "typebench $keys" >> "$cmdfile"
  until grep -q "^typebench .* keys:" "$cmdfile.log" 2>/dev/null; do sleep 0.5; done
  echo "run $i  $(grep '^typebench ' "$cmdfile.log" | tr '\n' ' ')  app cpu $(cpu $pid $app0) s  WindowServer cpu $(cpu $ws $ws0) s"
  kill $pid; wait $pid 2>/dev/null || true
  rm -f "$cmdfile" "$cmdfile.log"
done
cp "$original" "$folder/$note"
