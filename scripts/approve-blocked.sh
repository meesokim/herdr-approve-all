#!/usr/bin/env bash
# Approve every blocked agent pane (any agent: claude, codex, gemini, ...) by
# sending its confirm key, accepting the highlighted default (Yes) prompt.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

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

count=0
while read -r pane agent; do
  [ -n "$pane" ] || continue
  # shellcheck disable=SC2046
  "$HERDR" agent send-keys "$pane" $(keys_for "$agent") &
  count=$((count + 1))
done << EOF
$("$HERDR" agent list | json_eval \
  '.result.agents[] | select(.agent_status == "blocked") | "\(.pane_id) \(.agent // "unknown")"' \
  'for a in d.get("result", {}).get("agents", []):
    if a.get("agent_status") == "blocked":
        print(a["pane_id"], a.get("agent", "unknown"))')
EOF
wait

if [ "$count" -gt 0 ]; then
  s=""
  [ "$count" -gt 1 ] && s="s"
  "$HERDR" notification show "Approved $count agent$s" --sound none >/dev/null 2>&1 || true
fi
