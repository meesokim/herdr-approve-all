# Shared helpers. Sourced by the action/event/monitor scripts.

HERDR="${HERDR_BIN_PATH:-herdr}"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Tunables (env-overridable, mainly so the stub test can shrink the waits).
APPROVE_MAX_SENDS="${APPROVE_MAX_SENDS:-5}"       # confirm keys per pane, per run
APPROVE_LEAVE_TIMEOUT_MS="${APPROVE_LEAVE_TIMEOUT_MS:-1200}"
APPROVE_SETTLE_SEC="${APPROVE_SETTLE_SEC:-0.2}"   # let a queued prompt or TUI redraw paint
APPROVE_SCRAPE_FALLBACK="${APPROVE_SCRAPE_FALLBACK:-1}"
APPROVE_AUTO_POLL_SEC="${APPROVE_AUTO_POLL_SEC:-0.3}"
APPROVE_CMD_TIMEOUT_SEC="${APPROVE_CMD_TIMEOUT_SEC:-4}"
APPROVE_CONTINUE_COOLDOWN_SEC="${APPROVE_CONTINUE_COOLDOWN_SEC:-4}"

STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${HERDR_PLUGIN_CONFIG_DIR:-${TMPDIR:-/tmp}}/state}"
PID_FILE="$STATE_DIR/monitor.pid"
LOG_FILE="$STATE_DIR/monitor.log"

# run_herdr <args...>: invoke herdr with a hard timeout so a wedged socket call
# can never freeze the monitor or hold a pane lock forever.
run_herdr() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$APPROVE_CMD_TIMEOUT_SEC" "$HERDR" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$APPROVE_CMD_TIMEOUT_SEC" "$HERDR" "$@"
  else
    "$HERDR" "$@"
  fi
}

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

# list_sorted_agents: prints "<pane_id> <agent> <agent_status>" with blocked
# (red) panes first, working (green) panes second, and all others third.
list_sorted_agents() {
  run_herdr agent list 2>/dev/null | json_eval \
    '(.result.agents // []) | sort_by(if .agent_status == "blocked" then 0 elif .agent_status == "working" then 1 else 2 end) | .[] | "\(.pane_id) \(.agent // "unknown") \(.agent_status // "")"' \
    'order = {"blocked": 0, "working": 1}
for a in sorted(d.get("result", {}).get("agents") or [], key=lambda x: order.get(x.get("agent_status", ""), 2)):
    print(a.get("pane_id", ""), a.get("agent") or "unknown", a.get("agent_status") or "")'
}

# keys_for <agent>: keys to send to approve that agent's prompt.
# Enter confirms the highlighted default (Yes/Allow) in every supported agent's
# blocked prompt (claude, codex, gemini, agy, ...). Override per agent with a
# line "<agent>=<key> [key...]" in $HERDR_PLUGIN_CONFIG_DIR/keys.conf, e.g.
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

file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || date +%s
}

# take_lock <dir> <max_age_seconds>: mkdir-based mutex. A lock older than
# max_age is assumed to belong to a killed run and is taken over, so a crash can
# never wedge the plugin permanently.
take_lock() {
  local dir="$1" max="$2" now mt
  if mkdir "$dir" 2>/dev/null; then
    return 0
  fi
  now=$(date +%s)
  mt=$(file_mtime "$dir")
  if [ $((now - mt)) -lt "$max" ]; then
    return 1
  fi
  rmdir "$dir" 2>/dev/null || true
  mkdir "$dir" 2>/dev/null
}

pane_lock_path() {
  printf '%s/herdr-approve-all.pane.%s' "${TMPDIR:-/tmp}" \
    "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '_')"
}

continue_stamp_path() {
  printf '%s/herdr-approve-all.continue.%s' "${TMPDIR:-/tmp}" \
    "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '_')"
}

# agent_status <pane>: current status, or empty when the pane is gone.
agent_status() {
  run_herdr agent get "$1" 2>/dev/null | json_eval \
    '.result.agent.agent_status // empty' \
    'print(d.get("result", {}).get("agent", {}).get("agent_status", ""))'
}

# screen_active_region: strips conversation scrollback at and above an active
# composer box (20+ '─' border, '> ...' input line(s), 20+ '─' border) so
# markdown numbered lists or user-pasted prompt text in scrollback never
# false-trigger while an agent is working. Compatible with mawk, gawk, BSD awk.
screen_active_region() {
  awk '
    BEGIN { rule = "────────────────────"; state = 0; buf = "" }
    index($0, rule) > 0 {
      if (state == 2) { buf = ""; state = 0; next }
      state = 1
      buf = buf $0 "\n"
      next
    }
    state >= 1 && /^[[:space:]]*>/ {
      state = 2
      buf = buf $0 "\n"
      next
    }
    {
      state = 0
      buf = buf $0 "\n"
    }
    END { printf "%s", buf }
  '
}

# screen_has_prompt <screen_text>: true when active screen shows a live dialog.
# Supports both classic "esc to cancel" dialogs and agy permission menus where
# the footer may be omitted or scrolled off (sandbox bypass, outside-workspace).
screen_has_prompt() {
  local active
  [ -n "${1:-}" ] || return 1
  active=$(printf '%s\n' "$1" | tr -d '\r' | screen_active_region)
  [ -n "$active" ] || return 1
  if printf '%s\n' "$active" | grep -qiE '^[[:space:]]*(❯|>)[[:space:]]*1\.[[:space:]]+(Yes|Allow)([[:space:],]|$)'; then
    printf '%s\n' "$active" | grep -qiE '^[[:space:]]*2\.[[:space:]]+(Yes|No|Allow|Deny)([[:space:],]|$)|esc to cancel|Navigate|enter to (confirm|select)|Requesting permission for:|Run this command\?|Allow (sandbox bypass|access)|Reason:[[:space:]]*outside workspace|Do you want to' && return 0
  fi
  printf '%s\n' "$active" | grep -qi 'esc to cancel' || return 1
  printf '%s\n' "$active" | grep -qiE '^[[:space:]]*((❯|>)[[:space:]]*[0-9]+\.[[:space:]]+|1\.[[:space:]]+(Yes|Allow)([[:space:],-]|$))|enter to (confirm|select)'
}

# screen_needs_continue <screen_text>: true when transient server/network error
# sits at the bottom of the transcript right above an empty composer box (or end
# of screen), ignoring user-quoted (> ...) lines in scrollback.
screen_needs_continue() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "$1" | tr -d '\r' | awk '
    BEGIN { rule = "────────────────────"; matched = 0; box = 0 }
    !/^[[:space:]]*>/ && /[Tt]here was a network issue connecting to the server,[[:space:]]*please try again\./ {
      matched = 1
      box = 0
      next
    }
    matched {
      if (/^[[:space:]]*$/ || /^[[:space:]]*[Ee]rror ID:[[:space:]]*[^[:space:]]+/) next
      if (box == 0 && index($0, rule) > 0) { box = 1; next }
      if (box == 1 && /^[[:space:]]*>[[:space:]]*$/) { box = 2; next }
      if (box == 2 && index($0, rule) > 0) { box = 3; next }
      if (box == 3) {
        if (/[Rr]unning command/) { matched = 0; box = 0 }
        next
      }
      matched = 0
      box = 0
    }
    END { exit (matched && (box == 0 || box == 3) ? 0 : 1) }
  '
}

# screen_needs_ctrl_k <screen_text>: true when an active subagent approval
# banner (e.g. "┃ self needs approval for Bash" ... "┃ ctrl+k approve · alt+j manage")
# is waiting on screen, ignoring user-quoted (> ...) text in scrollback.
screen_needs_ctrl_k() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "$1" | tr -d '\r' | awk '
    BEGIN { rule = "────────────────────"; has_header = 0; in_user = 0; matched = 0; box = 0 }
    index($0, rule) > 0 && $0 !~ /^[[:space:]]*(┃|│|\|)/ {
      if (matched) {
        if (box == 0) { box = 1; next }
        if (box == 2) { box = 3; next }
      }
      in_user = 0
      next
    }
    /^[[:space:]]*>/ {
      if (matched && (box == 1 || box == 2)) { box = 2; next }
      in_user = 1
      has_header = 0
      matched = 0
      box = 0
      next
    }
    $0 !~ /^[[:space:]]*(┃|│|\|)/ {
      in_user = 0
    }
    !in_user && /[Nn]eeds approval( for )?/ {
      has_header = 1
    }
    !in_user && /[Cc]trl\+k[[:space:]]+(to[[:space:]]+)?approve/ && (has_header || /[Aa]lt\+j[[:space:]]+manage/ || /^[[:space:]]*(┃|│|\|)/) {
      matched = 1
      box = 0
      next
    }
    matched {
      if (/^[[:space:]]*$/ || /^[[:space:]]*(┃|│|\||└|├|●|✻|⣟|⣯|⣷|⣾|⣽|⣻|⢿|⡿)/) next
      if ((box == 0 || box == 3) && (/^[[:space:]]*(\?[[:space:]]+for[[:space:]]+shortcuts|[Ee]sc[[:space:]]+to[[:space:]]+cancel)/ || /(accept-edits|request-review|auto-approve)/)) next
      matched = 0
      box = 0
    }
    END { exit (matched && (box == 0 || box == 3) ? 0 : 1) }
  '
}

# pane_action <pane> [known_status]: prints "approve", "ctrl+k", "continue", or nothing.
# Reuses known_status when provided so blocked panes send keys immediately and
# working/idle panes perform only a single "agent read" call.
pane_action() {
  local pane="$1" status="${2:-}" out
  if [ -z "$status" ]; then
    status=$(agent_status "$pane")
  fi
  if [ "$status" = "blocked" ]; then
    printf 'approve'
    return 0
  fi
  [ "$APPROVE_SCRAPE_FALLBACK" = "1" ] || return 1
  out=$(run_herdr agent read "$pane" --source visible --lines 28 2>/dev/null) || return 1
  if screen_needs_ctrl_k "$out"; then
    printf 'ctrl+k'
    return 0
  fi
  if screen_has_prompt "$out"; then
    printf 'approve'
    return 0
  fi
  if screen_needs_continue "$out"; then
    printf 'continue'
    return 0
  fi
  return 1
}

prompt_visible() {
  local out
  [ "$APPROVE_SCRAPE_FALLBACK" = "1" ] || return 1
  out=$(run_herdr agent read "$1" --source visible --lines 28 2>/dev/null) || return 1
  screen_has_prompt "$out"
}

ctrl_k_needed() {
  local out
  [ "$APPROVE_SCRAPE_FALLBACK" = "1" ] || return 1
  out=$(run_herdr agent read "$1" --source visible --lines 28 2>/dev/null) || return 1
  screen_needs_ctrl_k "$out"
}

continue_needed() {
  local out
  [ "$APPROVE_SCRAPE_FALLBACK" = "1" ] || return 1
  out=$(run_herdr agent read "$1" --source visible --lines 28 2>/dev/null) || return 1
  screen_needs_continue "$out"
}

needs_approval() {
  pane_action "$1" "${2:-}" >/dev/null
}

# approve_pane <pane> <agent> [initial_status]: send the confirm key (or ctrl+k
# for subagent approvals, or "continue" on network errors), then VERIFY the pane
# left the blocked state.
approve_pane() {
  local pane="$1" agent="$2" initial_status="${3:-}" sent=0 last_action="" hint action cstamp now mt remaining
  while [ "$sent" -lt "$APPROVE_MAX_SENDS" ]; do
    if [ "$sent" -eq 0 ]; then
      hint="$initial_status"
    else
      hint=""
    fi
    action=$(pane_action "$pane" "$hint" || true)
    [ -n "$action" ] || break
    if [ "$action" = "continue" ]; then
      cstamp=$(continue_stamp_path "$pane")
      if [ -e "$cstamp" ]; then
        now=$(date +%s)
        mt=$(file_mtime "$cstamp")
        if [ $((now - mt)) -lt "${APPROVE_CONTINUE_COOLDOWN_SEC:-4}" ]; then
          break
        fi
      fi
      run_herdr agent prompt "$pane" continue >/dev/null 2>&1 || \
        run_herdr agent send-keys "$pane" c o n t i n u e enter >/dev/null 2>&1 || break
      : > "$cstamp" 2>/dev/null || true
      sent=$((sent + 1))
      last_action="continue"
      run_herdr agent wait "$pane" --until working \
        --timeout "$APPROVE_LEAVE_TIMEOUT_MS" >/dev/null 2>&1 || true
      sleep "$APPROVE_SETTLE_SEC"
      break
    fi
    if [ "$action" = "ctrl+k" ]; then
      run_herdr agent send-keys "$pane" ctrl+k >/dev/null 2>&1 || break
      sent=$((sent + 1))
      last_action="ctrl+k"
      if [ "$hint" = "blocked" ]; then
        run_herdr agent wait "$pane" --until idle --until working --until done \
          --timeout "$APPROVE_LEAVE_TIMEOUT_MS" >/dev/null 2>&1 || true
      fi
      sleep "$APPROVE_SETTLE_SEC"
      continue
    fi
    # shellcheck disable=SC2046
    run_herdr agent send-keys "$pane" $(keys_for "$agent") >/dev/null 2>&1 || break
    sent=$((sent + 1))
    last_action="approve"
    if [ -z "$hint" ] || [ "$hint" = "blocked" ]; then
      run_herdr agent wait "$pane" --until idle --until working --until done \
        --timeout "$APPROVE_LEAVE_TIMEOUT_MS" >/dev/null 2>&1 || true
    fi
    sleep "$APPROVE_SETTLE_SEC"
  done
  if [ "$sent" -eq 0 ]; then
    printf -- '-'
  elif [ "$last_action" = "continue" ]; then
    printf 1
  else
    remaining=$(pane_action "$pane" || true)
    if [ "$remaining" = "approve" ] || [ "$remaining" = "ctrl+k" ]; then
      printf 0
    else
      printf 1
    fi
  fi
}

monitor_running() {
  local pid
  [ -f "$PID_FILE" ] || return 1
  pid=$(cat "$PID_FILE" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

start_monitor() {
  [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  monitor_running && return 0
  local slock="$STATE_DIR/monitor.start.lock"
  take_lock "$slock" 5 || return 0
  if ! monitor_running; then
    nohup bash "$LIB_DIR/auto-toggle.sh" monitor >/dev/null 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$PID_FILE" 2>/dev/null || true
  fi
  rmdir "$slock" 2>/dev/null || true
}

stop_monitor() {
  local pid
  if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *) kill "$pid" 2>/dev/null || true ;;
    esac
    rm -f "$PID_FILE" 2>/dev/null || true
  fi
}
