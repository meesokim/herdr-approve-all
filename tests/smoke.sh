#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/herdr-approve-unix-test.XXXXXX")"
WORKER_PID=""

cleanup() {
  rm -f "$TMP/auto-approve" 2>/dev/null || true
  if [ -f "$TMP/state/monitor.pid" ]; then
    WORKER_PID="$(cat "$TMP/state/monitor.pid" 2>/dev/null || true)"
  fi
  if [ -n "${WORKER_PID:-}" ]; then
    kill "$WORKER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

send_count() {
  if [ -f "$TMP/sent" ]; then
    wc -l < "$TMP/sent" | tr -d '[:space:]'
  else
    printf '0'
  fi
}

wait_until() {
  local cond="$1" msg="$2" i=0
  while ! eval "$cond"; do
    i=$((i + 1))
    if [ "$i" -gt 300 ]; then
      echo "FAIL: $msg" >&2
      exit 1
    fi
    sleep 0.1
  done
}

export TMPDIR="$TMP"
export HERDR_PLUGIN_CONFIG_DIR="$TMP"
export HERDR_PLUGIN_STATE_DIR="$TMP/state"
export HERDR_BIN_PATH="$TMP/herdr"
export MOCK_HERDR_DIR="$TMP"
export APPROVE_AUTO_POLL_SEC="0.1"
export APPROVE_SETTLE_SEC="0.01"
export APPROVE_HOLD_POLL_SEC="0.01"
export APPROVE_HOLD_POLLS="1"
export APPROVE_IDLE_DEBOUNCE_SEC="0"
export APPROVE_CONTINUE_COOLDOWN_SEC="0"

cat > "$HERDR_BIN_PATH" << 'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "agent list")
    printf '%s\n' '{"result":{"agents":[{"pane_id":"pane-1","agent":"codex"}]}}'
    ;;
  "agent get")
    if [ -f "$MOCK_HERDR_DIR/pending" ]; then
      printf '%s\n' '{"result":{"agent":{"agent_status":"blocked"}}}'
    else
      printf '%s\n' '{"result":{"agent":{"agent_status":"working"}}}'
    fi
    ;;
  "agent read")
    if [ -f "$MOCK_HERDR_DIR/fallback_screen.txt" ]; then
      cat "$MOCK_HERDR_DIR/fallback_screen.txt"
    elif [ -f "$MOCK_HERDR_DIR/fallback" ]; then
      printf '%s\n' '1. Yes - enter to confirm - esc to cancel'
    fi
    ;;
  "agent send-keys")
    shift 3
    if [ -f "$MOCK_HERDR_DIR/queued" ]; then
      rm -f "$MOCK_HERDR_DIR/queued"
    else
      rm -f "$MOCK_HERDR_DIR/pending" "$MOCK_HERDR_DIR/fallback" "$MOCK_HERDR_DIR/fallback_screen.txt"
    fi
    printf '%s\n' "$*" >> "$MOCK_HERDR_DIR/sent"
    ;;
  "agent prompt")
    rm -f "$MOCK_HERDR_DIR/fallback_screen.txt"
    printf 'prompt:%s\n' "${4:-}" >> "$MOCK_HERDR_DIR/sent"
    ;;
esac
exit 0
EOF
chmod +x "$HERDR_BIN_PATH"

printf 'codex=y enter\n' > "$TMP/keys.conf"
: > "$TMP/pending"
: > "$TMP/queued"

bash "$ROOT/scripts/approve-blocked.sh"
[ "$(send_count)" = "2" ] || { echo "sweep did not drain stacked prompts" >&2; exit 1; }
[ "$(head -n 1 "$TMP/sent")" = "y enter" ] || { echo "sweep did not send configured keys" >&2; exit 1; }

# Verify agy sandbox-bypass prompt (no "esc to cancel" footer, rendered above composer box, including column-0 wrapped options in narrow split panes) while status is working/idle.
cat > "$TMP/fallback_screen.txt" << 'EOF'
🔓 Allow sandbox bypass for command execution?
⚠️ Confirm the command is safe to run outside of the sandbox with full network and disk access.

> 1. Yes, run command
  2. Yes, and always allow in this conversation for commands that start with
'powershell.exe -NoProfile'
  3. Yes, and always allow for commands that start with 'powershell.exe'
(Persist to settings.json)
  4. No, cancel
────────────────────────────────────────────────────────────
>
────────────────────────────────────────────────────────────
? for shortcuts                               accept-edits
EOF
bash "$ROOT/scripts/approve-blocked.sh"
[ "$(send_count)" = "3" ] || { echo "sweep missed agy sandbox-bypass prompt" >&2; exit 1; }

# Verify agy minimal "Run this command?\n> 1. Yes, run command" prompt (without Options 2-4 visible) while status is working/idle.
cat > "$TMP/fallback_screen.txt" << 'EOF'
Run this command?
> 1. Yes, run command
EOF
bash "$ROOT/scripts/approve-blocked.sh"
[ "$(send_count)" = "4" ] || { echo "sweep missed minimal Run this command? prompt" >&2; exit 1; }

# Verify agy outside-workspace file access prompt (including composer box and background task tray below) while status is working/idle.
cat > "$TMP/fallback_screen.txt" << 'EOF'
Reason: outside workspace

Allow access to this file?
> 1. Yes, allow access
  2. No, deny access
────────────────────────────────────────────────────────────
>
────────────────────────────────────────────────────────────
  ● [22:39:07] powershell -NoProfile -ExecutionPolicy Bypass -File test.ps1 running
────────────────────────────────────────────────────────────
esc to cancel                               accept-edits · 1 task(s) · /tasks
EOF
bash "$ROOT/scripts/approve-blocked.sh"
[ "$(send_count)" = "5" ] || { echo "sweep missed agy outside-workspace prompt" >&2; exit 1; }

# Verify agy file edit acceptance prompt ("Accept this file edit?") with non-accept-edits footer ("esc to cancel ... Gemini 4 Argon · medium") while status is working/idle/done.
cat > "$TMP/fallback_screen.txt" << 'EOF'
  shift+tab to auto-approve file edits
Accept this file edit?
> 1. Yes, accept this change
  2. No, reject this change

  ↑/↓ Navigate · f full diff
esc to cancel                                                                                                                                     Gemini 4 Argon · medium
EOF
bash "$ROOT/scripts/approve-blocked.sh"
[ "$(send_count)" = "6" ] || { echo "sweep missed agy file edit acceptance prompt" >&2; exit 1; }

# Verify transient network issue screen submits "continue".
cat > "$TMP/fallback_screen.txt" << 'EOF'
⚠ There was a network issue connecting to the server, please try again.
Error ID: 4e1156e0-393c-4a95-a07c-c79c7e8ec0bb-937

────────────────────────────────────────────────────────────
>
────────────────────────────────────────────────────────────
? for shortcuts                               accept-edits
EOF
bash "$ROOT/scripts/approve-blocked.sh"
[ "$(send_count)" = "7" ] || { echo "sweep did not submit continue on network error screen" >&2; exit 1; }
[ "$(tail -n 1 "$TMP/sent")" = "prompt:continue" ] || { echo "sweep did not send continue prompt" >&2; exit 1; }

# Verify agent executor stream idle timeout / context deadline exceeded error submits "continue".
cat > "$TMP/fallback_screen.txt" << 'EOF'
⚠ agent executor error: generating and executing: stream reading error: stream idle timeout (5m0s): context deadline exceeded
Error ID: 91998619-beee-4016-9622-358e1320cc2b-1795

────────────────────────────────────────────────────────────
>
────────────────────────────────────────────────────────────
? for shortcuts                               accept-edits
EOF
bash "$ROOT/scripts/approve-blocked.sh"
[ "$(send_count)" = "8" ] || { echo "sweep did not submit continue on stream idle timeout error screen" >&2; exit 1; }
[ "$(tail -n 1 "$TMP/sent")" = "prompt:continue" ] || { echo "sweep did not send continue prompt on stream error" >&2; exit 1; }

# Verify subagent approval banner ("ctrl+k approve · alt+j manage") sends ctrl+k in agy's live subagent tray layout
# (composer box above the tray, single horizontal border and status footer below).
cat > "$TMP/fallback_screen.txt" << 'EOF'
────────────────────────────────────────────────────────────
>
────────────────────────────────────────────────────────────
 ┃ research needs approval for Read
 ┃ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ┃
 ┃ ● Read(~/KDH/skills/mcp/server.py)
 ┃
 ┃ ctrl+k approve · alt+j manage
───────────────────────────────────
? for shortcuts                               accept-edits · 1 subagent(s)
EOF
bash "$ROOT/scripts/approve-blocked.sh"
[ "$(send_count)" = "9" ] || { echo "sweep did not send ctrl+k on subagent approval screen" >&2; exit 1; }
[ "$(tail -n 1 "$TMP/sent")" = "ctrl+k" ] || { echo "sweep did not send ctrl+k key" >&2; exit 1; }

# Verify CLI feedback survey ("How's the CLI experience so far? Help us improve:" / "[1] Good  [2] Fine  [3] Bad  [0] Skip") sends "0".
cat > "$TMP/fallback_screen.txt" << 'EOF'
How's the CLI experience so far? Help us improve:
 [1] Good  [2] Fine  [3] Bad  [0] Skip
────────────────────────────────────────────────────────────
>
────────────────────────────────────────────────────────────
? for shortcuts                               accept-edits
EOF
bash "$ROOT/scripts/approve-blocked.sh"
[ "$(send_count)" = "10" ] || { echo "sweep did not send 0 on CLI experience survey screen" >&2; exit 1; }
[ "$(tail -n 1 "$TMP/sent")" = "0" ] || { echo "sweep did not send 0 key" >&2; exit 1; }

# Verify normal working screen with markdown list + quoted network/stream error + quoted ctrl+k banner + quoted survey + composer box does NOT false-trigger.
cat > "$TMP/fallback_screen.txt" << 'EOF'
  1. First normal markdown list item in scrollback
  2. Second normal markdown list item in scrollback
  > 🔓 Allow sandbox bypass for command execution?
    > 1. Yes, run command
      2. Yes, and always allow in this conversation for commands that start with 'ls'
      3. Yes, and always allow for commands that start with 'ls' (Persist to settings.json)
      4. No, cancel
  > Run this command?
    > 1. Yes, run command
  > Accept this file edit?
    > 1. Yes, accept this change
      2. No, reject this change
  > Reason: outside workspace

    Allow access to this file?
    > 1. Yes, allow access
      2. No, deny access
  > How's the CLI experience so far? Help us improve:
   [1] Good  [2] Fine  [3] Bad  [0] Skip
  > ⚠ There was a network issue connecting to the server, please try again.
    Error ID: 4e1156e0-393c-4a95-a07c-c79c7e8ec0bb-937
  > ⚠ agent executor error: generating and executing: stream reading error: stream idle timeout (5m0s): context deadline exceeded
    Error ID: 91998619-beee-4016-9622-358e1320cc2b-1795
  > ┃ self needs approval for Bash
   ┃ ────────────────────────────────────────────────────────────
   ┃ ● Bash(git status)
   ┃ ctrl+k approve · alt+j manage

Running command...

────────────────────────────────────────────────────────────
>
────────────────────────────────────────────────────────────
esc to cancel                               accept-edits
EOF
bash "$ROOT/scripts/approve-blocked.sh"
[ "$(send_count)" = "10" ] || { echo "sweep falsely triggered on normal working screen" >&2; exit 1; }
rm -f "$TMP/fallback_screen.txt"

# Verify background monitor in auto mode handles blocked and working prompts without events.
bash "$ROOT/scripts/auto-toggle.sh" on
[ -f "$TMP/auto-approve" ] || { echo "on did not create flag" >&2; exit 1; }
wait_until '[ -f "$TMP/state/monitor.pid" ]' 'monitor did not start'
WORKER_PID="$(cat "$TMP/state/monitor.pid")"

: > "$TMP/pending"
wait_until '[ "$(send_count)" -ge 11 ]' 'first automatic prompt was missed'
wait_until '[ ! -f "$TMP/pending" ]' 'first prompt did not settle'

: > "$TMP/fallback"
wait_until '[ "$(send_count)" -ge 12 ]' 'prompt reported as working was missed'

bash "$ROOT/scripts/auto-toggle.sh" off
[ ! -f "$TMP/auto-approve" ] || { echo "off did not remove flag" >&2; exit 1; }
wait_until '[ ! -f "$TMP/state/monitor.pid" ]' 'monitor did not stop after off'

echo "Unix smoke test passed"
