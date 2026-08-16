#!/usr/bin/env bash
# Event handler for pane.agent_status_changed.
# When auto-approve is enabled and an agent turns blocked, approve it instantly.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ -f "${HERDR_PLUGIN_CONFIG_DIR:-/nonexistent}/auto-approve" ] || exit 0

EVENT="${HERDR_PLUGIN_EVENT_JSON:-}"
[ -n "$EVENT" ] || exit 0

read -r status pane agent << EOF
$(printf '%s' "$EVENT" | json_eval \
  '.data | "\(.agent_status) \(.pane_id) \(.agent // "unknown")"' \
  'x = d.get("data", {})
print(x.get("agent_status", "?"), x.get("pane_id", "?"), x.get("agent", "unknown"))')
EOF

[ "$status" = "blocked" ] || exit 0
[ "$pane" != "?" ] || exit 0

# The pane lock keeps this handler and a manual sweep from driving the same pane
# at once. approve_pane drains the prompts queued behind this one: while a pane
# stays blocked the status never changes, so this event does not fire again.
lock=$(pane_lock_path "$pane")
take_lock "$lock" 60 || exit 0
trap 'rmdir "$lock" 2>/dev/null || true' EXIT HUP INT TERM
approve_pane "$pane" "$agent" >/dev/null
