#!/usr/bin/env bash
# Toggle the auto-approve flag (a marker file in the plugin config dir).
set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
FLAG="$HERDR_PLUGIN_CONFIG_DIR/auto-approve"

case "${1:-}" in
  on)
    mkdir -p "$HERDR_PLUGIN_CONFIG_DIR"
    touch "$FLAG"
    "$HERDR" notification show "Auto-approve ON" --body "Every agent that turns blocked gets Enter automatically." --sound none
    ;;
  off)
    rm -f "$FLAG"
    "$HERDR" notification show "Auto-approve OFF" --sound none
    ;;
  *)
    echo "usage: auto-toggle.sh on|off" >&2
    exit 1
    ;;
esac
