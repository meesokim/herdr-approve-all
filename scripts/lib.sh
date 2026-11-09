# Shared helpers. Sourced by the action/event/monitor scripts.

HERDR="${HERDR_BIN_PATH:-herdr}"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Tunables (env-overridable, mainly so the stub test can shrink the waits).
APPROVE_MAX_SENDS="${APPROVE_MAX_SENDS:-5}"       # confirm keys per pane, per run
APPROVE_LEAVE_TIMEOUT_MS="${APPROVE_LEAVE_TIMEOUT_MS:-1200}"
APPROVE_SETTLE_SEC="${APPROVE_SETTLE_SEC:-0.12}"  # let a queued prompt or TUI redraw paint
APPROVE_SCRAPE_FALLBACK="${APPROVE_SCRAPE_FALLBACK:-1}"
APPROVE_AUTO_POLL_SEC="${APPROVE_AUTO_POLL_SEC:-0.15}"
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

# list_sorted_agents: prints "<pane_id> <agent> <agent_status> <focused> <state_key>"
# with blocked (red) panes first, focused+working second, working third, focused fourth, and others fifth.
list_sorted_agents() {
  run_herdr agent list 2>/dev/null | json_eval \
    '(.result.agents // []) | sort_by(if .agent_status == "blocked" then 0 elif (.agent_status == "working" and .focused == true) then 1 elif .agent_status == "working" then 2 elif .focused == true then 3 else 4 end) | .[] | "\(.pane_id) \(if (.agent // "") == "" then "unknown" else .agent end) \(.agent_status // "") \(.focused // false) \(.agent_status // ""):\(.state_change_seq // 0):\(.revision // 0)"' \
    'def rank(x):
    st = x.get("agent_status", "")
    foc = bool(x.get("focused", False))
    if st == "blocked": return 0
    if st == "working" and foc: return 1
    if st == "working": return 2
    if foc: return 3
    return 4
for a in sorted(d.get("result", {}).get("agents") or [], key=rank):
    st = a.get("agent_status") or ""
    foc = "true" if a.get("focused") else "false"
    sk = f"{st}:{a.get(\"state_change_seq\", 0)}:{a.get(\"revision\", 0)}"
    print(a.get("pane_id", ""), a.get("agent") or "unknown", st, foc, sk)'
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
  local out
  out=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true)
  case "$out" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$out" ;;
  esac
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

# screen_has_prompt <screen_text>: true when active screen shows a live dialog.
# Supports both classic "esc to cancel" dialogs and agy permission menus
# (sandbox bypass, outside-workspace file access, command execution) whether
# rendered above or in place of the composer box, while ignoring scrollback.
# Compatible with mawk, gawk, BSD awk.
screen_has_prompt() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "$1" | tr -d '\r' | awk '
    BEGIN { rule = "──────────"; has_cue = 0; has_opt1 = 0; matched = 0; in_quote = 0 }
    index($0, rule) > 0 && $0 !~ /^[[:space:]]*(┃|│|\|)/ {
      in_quote = 0
      next
    }
    /^[[:space:]]*>[[:space:]]*$/ { next }
    /([Rr]unning command\.\.\.|[Rr]eading file\.\.\.|[Ee]diting file|[Tt]hinking\.\.\.|[Ll]oading\.\.\.|[Tt]hought for [0-9]|[0-9.]+k[[:space:]]+in[[:space:]]*\||Conversation compacted)/ {
      has_cue = 0; has_opt1 = 0; matched = 0; in_quote = 0
      next
    }
    !in_quote && /^[[:space:]]*(┃|│|\|)?[[:space:]]*((❯|>)[[:space:]]*[0-9]+\.[[:space:]]+|1\.[[:space:]]+([Yy]es|[Aa]llow|[Aa]ccept)([[:space:],-]|$)).*([Ee]nter to (confirm|select)|[Ee]sc to cancel)/ {
      has_opt1 = 1; matched = 1
      next
    }
    !in_quote && /^[[:space:]]*(┃|│|\|)?[[:space:]]*(❯|>)[[:space:]]*1\.[[:space:]]+([Yy]es|[Aa]llow|[Aa]ccept)([[:space:],-]|$)/ {
      has_opt1 = 1
      if (has_cue) matched = 1
      next
    }
    /^[[:space:]]*>/ {
      in_quote = 1
      has_cue = 0; has_opt1 = 0; matched = 0
      next
    }
    in_quote {
      if (/^[[:space:]]*$/ || (/^[[:space:]]+/ && $0 !~ /^[[:space:]]*(┃|│|\||●|○|✻)/)) next
      in_quote = 0
    }
    has_opt1 && (/^[[:space:]]*(┃|│|\|)?[[:space:]]*[2-9]\.[[:space:]]+([Yy]es|[Nn]o|[Aa]llow|[Dd]eny|[Aa]ccept|[Rr]eject)([[:space:],-]|$)/ || /^[[:space:]]*(┃|│|\|)?[[:space:]]*(.*([Nn]avigate|tab [Aa]mend|ctrl\+g|[Ee]nter to (confirm|select))|[Ee]sc to cancel[[:space:]]*$)/) {
      matched = 1
      next
    }
    /([Aa]llow (sandbox bypass|access|calling|creation|administrator|remote)|[Aa]ccept this file edit\?|[Cc]onfirm the command is safe|[Rr]equesting permission for:|[Rr]un this command\?|[Rr]eason:[[:space:]]*outside workspace|[Dd]o you want to)/ {
      has_cue = 1
      next
    }
    !matched && has_opt1 && !/^[[:space:]]*$/ {
      has_opt1 = 0
    }
    END { exit (matched ? 0 : 1) }
  '
}

screen_is_false_blocked() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "$1" | tr -d '\r' | awk '
    BEGIN { rule = "────────────────────"; box = 0; busy = 0 }
    /([Rr]unning command\.\.\.|[Rr]eading file\.\.\.|[Tt]hinking\.\.\.|[Pp]ress up to edit queued messages)/ { busy = 1 }
    box == 0 && index($0, rule) > 0 { box = 1; next }
    box == 1 && /^[[:space:]]*>[[:space:]]*$/ { box = 2; next }
    box == 2 && index($0, rule) > 0 { box = 3; next }
    END { exit (busy && box == 3 ? 0 : 1) }
  '
}

# screen_needs_continue <screen_text>: true when transient server/network/stream
# error sits at the bottom of the transcript right above an empty composer box
# (or end of screen), ignoring user-quoted (> ...) lines in scrollback.
screen_needs_continue() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "$1" | tr -d '\r' | awk '
    BEGIN { rule = "──────────"; matched = 0; saw_id = 0; box = 0 }
    !/^[[:space:]]*>/ && /([Tt]here was a network issue connecting to the server,[[:space:]]*please try again\.|[Aa]gent executor error:|[Ss]tream reading error:|[Ss]tream idle timeout|[Cc]ontext deadline exceeded)/ {
      matched = 1
      saw_id = 0
      box = 0
      next
    }
    matched {
      if (/^[[:space:]]*$/) next
      if (/^[[:space:]]*[Ee]rror ID:[[:space:]]*[^[:space:]]+/) { saw_id = 1; next }
      if (box == 0 && !saw_id && !/^[[:space:]]*>/ && /(generating and executing|stream|timeout|deadline exceeded|please try again)/) next
      if (box == 0 && index($0, rule) > 0) { box = 1; next }
      if (box == 1 && /^[[:space:]]*>[[:space:]]*$/) { box = 2; next }
      if (box == 2 && index($0, rule) > 0) { box = 3; next }
      if (box == 3) {
        if (/([Rr]unning command|[Rr]eading file|[Tt]hinking)/) { matched = 0; box = 0 }
        next
      }
      matched = 0
      saw_id = 0
      box = 0
    }
    END { exit (matched && (box == 0 || box == 3) ? 0 : 1) }
  '
}

# screen_needs_ctrl_k <screen_text>: true when an active subagent approval
# banner (e.g. "┃ research needs approval for Read" ... "┃ ctrl+k approve · alt+j manage")
# is waiting on screen, ignoring user-quoted (> ...) text in scrollback.
screen_needs_ctrl_k() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "$1" | tr -d '\r' | awk '
    BEGIN { rule = "──────────"; has_header = 0; matched = 0; box = 0 }
    index($0, rule) > 0 && $0 !~ /^[[:space:]]*(┃|│|\|)/ {
      if (matched) {
        if (box == 0) { box = 1; next }
        if (box == 2 || box == 1 || box == 3) { box = 3; next }
      }
      next
    }
    /^[[:space:]]*>/ {
      if (matched && (box == 1 || box == 2) && /^[[:space:]]*>[[:space:]]*$/) { box = 2; next }
      has_header = 0
      matched = 0
      box = 0
      next
    }
    /[Nn]eeds approval( for )?/ {
      has_header = 1
    }
    /[Cc]trl\+k[[:space:]]+(to[[:space:]]+)?approve/ && (has_header || /[Aa]lt\+j[[:space:]]+manage/ || /^[[:space:]]*(┃|│|\|)/) {
      matched = 1
      box = 0
      next
    }
    matched {
      if (/^[[:space:]]*$/ || /^[[:space:]]*(┃|│|\||└|├|↳|●|○|✻|⣟|⣯|⣷|⣾|⣽|⣻|⢿|⡿)/) next
      if ((box == 0 || box == 1 || box == 3) && (/^[[:space:]]*(\?[[:space:]]+for[[:space:]]+shortcuts|[Ee]sc[[:space:]]+to[[:space:]]+cancel)/ || /(accept-edits|request-review|auto-approve|subagent\(s\))/)) next
      matched = 0
      box = 0
    }
    END { exit (matched && (box == 0 || box == 1 || box == 3) ? 0 : 1) }
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
    if [ "$APPROVE_SCRAPE_FALLBACK" = "1" ]; then
      out=$(run_herdr agent read "$pane" --source visible --lines 40 2>/dev/null || true)
      if [ -n "$out" ]; then
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
        if screen_is_false_blocked "$out"; then
          return 1
        fi
      fi
    fi
    printf 'approve'
    return 0
  fi
  [ "$APPROVE_SCRAPE_FALLBACK" = "1" ] || return 1
  out=$(run_herdr agent read "$pane" --source visible --lines 40 2>/dev/null) || return 1
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
  out=$(run_herdr agent read "$1" --source visible --lines 40 2>/dev/null) || return 1
  screen_has_prompt "$out"
}

ctrl_k_needed() {
  local out
  [ "$APPROVE_SCRAPE_FALLBACK" = "1" ] || return 1
  out=$(run_herdr agent read "$1" --source visible --lines 40 2>/dev/null) || return 1
  screen_needs_ctrl_k "$out"
}

continue_needed() {
  local out
  [ "$APPROVE_SCRAPE_FALLBACK" = "1" ] || return 1
  out=$(run_herdr agent read "$1" --source visible --lines 40 2>/dev/null) || return 1
  screen_needs_continue "$out"
}

needs_approval() {
  pane_action "$1" "${2:-}" >/dev/null
}

# approve_pane <pane> <agent> [initial_status] [auto_mode]: send the confirm key (or ctrl+k
# for subagent approvals, or "continue" on network errors), then VERIFY the pane
# left the blocked state.
approve_pane() {
  local pane="$1" agent="$2" initial_status="${3:-}" auto_mode="${4:-0}" sent=0 last_action="" cleared=0 hint action cstamp now mt remaining
  while [ "$sent" -lt "$APPROVE_MAX_SENDS" ]; do
    if [ "$sent" -eq 0 ]; then
      hint="$initial_status"
    else
      hint=""
    fi
    action=$(pane_action "$pane" "$hint" || true)
    if [ -z "$action" ]; then
      cleared=1
      break
    fi
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
      cleared=1
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
      if [ "$auto_mode" = "1" ] && [ -n "$hint" ] && [ "$hint" != "blocked" ]; then
        cleared=1
        break
      fi
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
    if [ "$auto_mode" = "1" ] && [ -n "$hint" ] && [ "$hint" != "blocked" ]; then
      cleared=1
      break
    fi
  done
  if [ "$sent" -eq 0 ]; then
    printf -- '-'
  elif [ "$cleared" = "1" ] || [ "$last_action" = "continue" ]; then
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
    if command -v setsid >/dev/null 2>&1; then
      setsid bash "$LIB_DIR/auto-toggle.sh" monitor >/dev/null 2>&1 < /dev/null &
    else
      nohup bash "$LIB_DIR/auto-toggle.sh" monitor >/dev/null 2>&1 < /dev/null &
    fi
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
