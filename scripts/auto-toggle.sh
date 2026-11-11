#!/usr/bin/env bash
# Toggle the auto-approve flag and manage the background monitor on Linux/macOS.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

FLAG="${HERDR_PLUGIN_CONFIG_DIR:?HERDR_PLUGIN_CONFIG_DIR is required}/auto-approve"

case "${1:-}" in
  on)
    chmod +x "$LIB_DIR/dispatch" 2>/dev/null || true
    mkdir -p "$HERDR_PLUGIN_CONFIG_DIR"
    touch "$FLAG"
    stop_monitor
    start_monitor
    run_herdr notification show "Auto-approve ON" --body "Every waiting agent prompt is approved automatically." --sound none >/dev/null 2>&1 || true
    ;;
  off)
    rm -f "$FLAG"
    stop_monitor
    run_herdr notification show "Auto-approve OFF" --sound none >/dev/null 2>&1 || true
    ;;
  startup)
    chmod +x "$LIB_DIR/dispatch" 2>/dev/null || true
    if [ -f "$FLAG" ]; then
      start_monitor
    fi
    ;;
  monitor)
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    if [ -f "$PID_FILE" ]; then
      existing=$(cat "$PID_FILE" 2>/dev/null || true)
      if [ -n "$existing" ] && [ "$existing" != "$$" ] && kill -0 "$existing" 2>/dev/null; then
        sleep 0.1
        existing=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$existing" ] && [ "$existing" != "$$" ] && kill -0 "$existing" 2>/dev/null; then
          exit 0
        fi
      fi
    fi
    printf '%s\n' "$$" > "$PID_FILE"
    trap '' HUP
    trap '
      if [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$PID_FILE" 2>/dev/null || true
      fi
      exit 0
    ' INT TERM
    trap '
      if [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$PID_FILE" 2>/dev/null || true
      fi
    ' EXIT
    idle_cache=""
    tick=0
    while [ -f "$FLAG" ]; do
      tick=$((tick + 1))
      if [ $((tick % 20)) -eq 0 ]; then
        idle_cache=""
      fi
      if [ -f "$STATE_DIR/hot-pane.txt" ]; then
        hot_pane=$(head -n 1 "$STATE_DIR/hot-pane.txt" 2>/dev/null || true)
        rm -f "$STATE_DIR/hot-pane.txt" 2>/dev/null || true
        if [ -n "$hot_pane" ]; then
          idle_cache=$(printf '%s\n' "$idle_cache" | grep -v "^${hot_pane}=" || true)
        fi
      fi
      pane_idx=0
      while read -r pane agent status focused state_key; do
        [ -f "$FLAG" ] || break
        [ -n "$pane" ] || continue
        pane_idx=$((pane_idx + 1))
        [ "${status:-}" = "?" ] && status=""
        cache_entry="$pane=${state_key:-}"
        if { [ "${status:-}" = "idle" ] || [ "${status:-}" = "done" ]; } && [ "${focused:-false}" != "true" ] && [ "$pane_idx" -gt 1 ]; then
          case "
$idle_cache
" in
            *"
$cache_entry
"*)
              continue
              ;;
            *)
              idle_cache="$idle_cache
$cache_entry"
              ;;
          esac
        else
          case "
$idle_cache
" in
            *"
stuck:$cache_entry
"*)
              continue
              ;;
          esac
        fi
        lock=$(pane_lock_path "$pane")
        if take_lock "$lock" 15; then
          res=$(approve_pane "$pane" "$agent" "${status:-}" 1 || printf -- '-')
          rmdir "$lock" 2>/dev/null || true
          if [ "$res" = "1" ]; then
            idle_cache=""
            printf '%s pane=%s result=%s\n' "$(date -Iseconds 2>/dev/null || date)" "$pane" "$res" >> "$LOG_FILE" 2>/dev/null || true
          elif [ "$res" = "0" ]; then
            idle_cache="$idle_cache
stuck:$cache_entry"
            printf '%s pane=%s result=%s\n' "$(date -Iseconds 2>/dev/null || date)" "$pane" "$res" >> "$LOG_FILE" 2>/dev/null || true
          fi
        fi
      done << EOF
$(list_sorted_agents 2>/dev/null || true)
EOF
      sleep "${APPROVE_AUTO_POLL_SEC:-0.15}"
    done
    ;;
  *)
    echo "usage: auto-toggle.sh on|off|startup|monitor" >&2
    exit 1
    ;;
esac
