#!/usr/bin/env bash
# Event handler for pane.agent_status_changed.
# When auto-approve is enabled and an agent turns blocked, approve it instantly.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ -f "${HERDR_PLUGIN_CONFIG_DIR:-/nonexistent}/auto-approve" ] || exit 0
was_running=0
if monitor_running; then
  was_running=1
else
  start_monitor
fi

EVENT="${HERDR_PLUGIN_EVENT_JSON:-}"
[ -n "$EVENT" ] || exit 0

read -r status pane agent << EOF
$(printf '%s' "$EVENT" | json_eval \
  '.data | "\(if (.agent_status // "") == "" then "?" else .agent_status end) \(if (.pane_id // "") == "" then "?" else .pane_id end) \(if (.agent // "") == "" then "unknown" else .agent end)"' \
  'x = d.get("data", {})
print(x.get("agent_status") or "?", x.get("pane_id") or "?", x.get("agent") or "unknown")')
EOF

[ "$pane" != "?" ] && [ -n "$pane" ] || exit 0

mkdir -p "$STATE_DIR" 2>/dev/null || true
printf '%s\n' "$pane" > "$STATE_DIR/hot-pane.txt" 2>/dev/null || true

if [ "$status" != "blocked" ] && [ "$was_running" = "1" ]; then
  exit 0
fi

# The pane lock keeps this handler, the background monitor, and a manual sweep
# from driving the same pane at once. Passing "blocked" skips the redundant
# agent_status() check before sending the first confirm key; other statuses
# inspect the visible screen for agy permission menus, ctrl+k, or continue.
lock=$(pane_lock_path "$pane")
take_lock "$lock" 15 || exit 0
trap 'rmdir "$lock" 2>/dev/null || true' EXIT HUP INT TERM
res=$(approve_pane "$pane" "$agent" "$status" 1 || printf -- '-')
if [ "$res" = "-" ] && [ "$status" != "blocked" ]; then
  sleep 0.12
  approve_pane "$pane" "$agent" "" 1 >/dev/null || true
fi
