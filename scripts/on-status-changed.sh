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

# shellcheck disable=SC2046
"$HERDR" agent send-keys "$pane" $(keys_for "$agent")
