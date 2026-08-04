#!/usr/bin/env bash
# Send Enter to every blocked agent pane, accepting the highlighted default
# option (Yes) on each pending prompt.
set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"

"$HERDR" agent list | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('result', {}).get('agents', []):
    if a.get('agent_status') == 'blocked':
        print(a['pane_id'])
" | while read -r pane; do
  "$HERDR" agent send-keys "$pane" enter
done
