#!/bin/bash
# Runs `swift test` with a watchdog. If the run takes longer than TEST_TIMEOUT seconds, every test process
# is sampled (stack traces of all threads) so a hang shows where it is stuck, then the run is killed.
set -uo pipefail

TIMEOUT="${TEST_TIMEOUT:-300}"
LOG="${RUNNER_TEMP:-/tmp}/swift-test.log"

swift build --build-tests || exit 1

swift test --skip-build "$@" > "$LOG" 2>&1 &
PID=$!
SECS=0
while kill -0 "$PID" 2>/dev/null && (( SECS < TIMEOUT )); do sleep 1; SECS=$((SECS + 1)); done

if kill -0 "$PID" 2>/dev/null; then
  echo "::error::swift test still running after ${TIMEOUT}s; sampling test processes"
  ps -axo pid,ppid,etime,command | grep -E "swiftpm-testing|xctest|PackageTests" | grep -v grep
  for p in $(pgrep -f "swiftpm-testing-helper|xctest|PackageTests"); do
    echo "===== sample $p"
    OUT="${RUNNER_TEMP:-/tmp}/sample-$p.txt"
    if sample "$p" 3 -mayDie -file "$OUT" >/dev/null 2>&1; then
      sed -n '/Call graph:/,/Total number in stack/p' "$OUT"
    else
      lldb -p "$p" --batch -o "thread backtrace all" 2>&1 | head -400
    fi
  done
  pkill -P "$PID" 2>/dev/null; kill "$PID" 2>/dev/null
  pkill -f "swiftpm-testing-helper" 2>/dev/null
  echo "===== partial test output"
  cat "$LOG"
  exit 1
fi

wait "$PID"; STATUS=$?
cat "$LOG"
exit "$STATUS"
