# Shared helpers. Sourced by the action/event scripts.

HERDR="${HERDR_BIN_PATH:-herdr}"

# json_eval <jq filter> <python body>: run the jq filter when jq is available
# (instant), else the python equivalent (interpreter startup can cost ~1s).
json_eval() {
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1"
  else
    python3 -c "
import sys, json
d = json.load(sys.stdin)
$2"
  fi
}

# keys_for <agent>: keys to send to approve that agent's prompt.
# Enter confirms the highlighted default (Yes/Allow) in every supported agent's
# blocked prompt (claude, codex, gemini, ...). Override per agent with a line
# "<agent>=<key> [key...]" in $HERDR_PLUGIN_CONFIG_DIR/keys.conf, e.g.
#   codex=y enter
keys_for() {
  local conf="${HERDR_PLUGIN_CONFIG_DIR:-}/keys.conf" line
  if [ -f "$conf" ]; then
    line=$(grep -m1 "^${1}=" "$conf" 2>/dev/null || true)
    if [ -n "$line" ]; then
      printf '%s' "${line#*=}"
      return
    fi
  fi
  printf 'enter'
}
