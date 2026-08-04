#!/usr/bin/env bash
# Send Enter to every blocked agent pane, accepting the highlighted default
# option (Yes) on each pending prompt.
set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"

# Debounce: key auto-repeat can fire this action dozens of times per second,
# tripping herdr's concurrent plugin command cap (32). First instance wins;
# repeats while the lock is fresh exit immediately.
LOCK="${TMPDIR:-/tmp}/herdr-approve-all.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  now=$(date +%s)
  mt=$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo "$now")
  if [ $((now - mt)) -lt 10 ]; then
    exit 0
  fi
  # stale lock from a killed run: steal it
  rmdir "$LOCK" 2>/dev/null || true
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# jq when available (instant); python3 fallback (interpreter startup can cost ~1s)
list_blocked() {
  if command -v jq >/dev/null 2>&1; then
    "$HERDR" agent list | jq -r '.result.agents[] | select(.agent_status == "blocked") | .pane_id'
  else
    "$HERDR" agent list | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('result', {}).get('agents', []):
    if a.get('agent_status') == 'blocked':
        print(a['pane_id'])
"
  fi
}

for pane in $(list_blocked); do
  "$HERDR" agent send-keys "$pane" enter &
done
wait
