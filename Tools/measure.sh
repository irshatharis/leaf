#!/bin/zsh
# Launches a built app on a notes folder and reports time to first window, resting memory and idle CPU.
# Usage: Tools/measure.sh [app] [folder] [runs]
set -eu
app=${1:-build/Build/Products/Release/Leaf.app}
folder=${2:-$HOME/vaults/irsh-world}
runs=${3:-3}
exe="$app/Contents/MacOS/$(defaults read "$PWD/$app/Contents/Info" CFBundleExecutable)"
name=${exe:t}

for i in $(seq $runs); do
  pkill -x "$name" 2>/dev/null && sleep 1 || true
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  "$exe" -NotebookLibrary "$folder" >/dev/null 2>&1 &
  pid=$!
  until [[ $(osascript -e "tell application \"System Events\" to count windows of (first process whose unix id is $pid)" 2>/dev/null) -ge 1 ]]; do sleep 0.05; done
  t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  sleep 10
  mem=$(footprint $pid | sed -nE 's/.*Footprint: ([0-9.]+ [KMG]B).*/\1/p' | head -1)
  peak=$(footprint $pid | sed -nE 's/.*phys_footprint_peak: ([0-9.]+ [KMG]B).*/\1/p' | head -1)
  cpu=$(top -l 4 -s 2 -pid $pid -stats cpu | tail -3 | awk '{s+=$1} END {printf "%.1f", s/NR}')
  printf "run %d  window %.2fs  footprint %s  peak %s  idle cpu %s%%\n" $i $((t1 - t0)) "$mem" "$peak" "$cpu"
  kill $pid; wait $pid 2>/dev/null || true
done
