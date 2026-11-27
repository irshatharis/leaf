#!/bin/zsh
# Launches a built app on a notes folder and reports time to first window, resting memory and idle CPU.
# With a note (its title in the sidebar, at the top of the folder), the note is opened, the keyboard put in its text
# and the app brought forward for the measurement, which is how it rests while you write; the app that was in front
# gets the front back after.
# Usage: Tools/measure.sh [app] [folder] [runs] [note]
set -eu
app=${1:-build/Build/Products/Release/Leaf.app}
folder=${2:-$HOME/vaults/irsh-world}
runs=${3:-3}
note=${4:-}
exe="$app/Contents/MacOS/$(defaults read "${app:A}/Contents/Info" CFBundleExecutable)"
if [[ -n $note ]]; then
  focusnote=$(mktemp -d)/focusnote
  DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} xcrun swiftc -O "${0:A:h}/focusnote.swift" -o $focusnote
fi

for i in $(seq $runs); do
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  "$exe" -NotebookLibrary "$folder" >/dev/null 2>&1 &
  pid=$!
  until [[ $(osascript -e "tell application \"System Events\" to count windows of (first process whose unix id is $pid)" 2>/dev/null) -ge 1 ]]; do sleep 0.05; done
  t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  if [[ -n $note ]]; then
    sleep 4
    out=$(mktemp)
    $focusnote $pid "$note" 6 > $out &
    helper=$!
    until grep -qE "^front|^no " $out; do sleep 0.1; done
    state=$(head -1 $out)
  else
    sleep 10
    state=""
  fi
  report=$(footprint $pid)
  mem=$(sed -nE 's/.*Footprint: ([0-9.]+ [KMG]B).*/\1/p' <<< $report | head -1)
  peak=$(sed -nE 's/.*phys_footprint_peak: ([0-9.]+ [KMG]B).*/\1/p' <<< $report | head -1)
  gpu=$(sed -nE 's/^ *([0-9.]+ [KMG]?B) .*Owned physical footprint \(unmapped\) \(graphics\)$/\1/p' <<< $report | head -1)
  cpu=$(top -l 4 -s 2 -pid $pid -stats cpu | tail -3 | awk '{s+=$1} END {printf "%.1f", s/NR}')
  [[ -n $note ]] && wait $helper
  printf "run %d  window %.2fs  footprint %s  graphics %s  peak %s  idle cpu %s%%  %s\n" $i $((t1 - t0)) "$mem" "${gpu:-0 B}" "$peak" "$cpu" "$state"
  kill $pid; wait $pid 2>/dev/null || true
done
