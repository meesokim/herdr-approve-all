#!/usr/bin/env bash
# Approve every waiting agent pane (any agent: claude, codex, gemini, agy, ...)
# by sending its confirm key (or "continue" on transient network errors), then
# verifying the pane actually left the blocked state.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

# Key auto-repeat is used, not fought. Holding the key down means "keep saying
# yes": the first instance takes LOCK and keeps sweeping; every repeat that
# arrives while it runs just drops a marker in the lock dir and exits in ~10ms,
# so herdr's concurrent plugin command cap (32) is never approached. When the
# key comes up the markers stop, the sweeper sees an empty grace window and
# exits.
#
# STAMP is the only debounce left, and it applies to a sweep that found NOTHING:
# without it a held key with no prompts on screen would re-list the fleet as
# fast as bash can fork. A sweep that DID approve something sets no window, so
# a deliberate re-press is always honoured immediately.
LOCK="${TMPDIR:-/tmp}/herdr-approve-all.lock"
REPEAT="$LOCK/repeat"
STAMP="${TMPDIR:-/tmp}/herdr-approve-all.empty-stamp"
IDLE_DEBOUNCE_SEC="${APPROVE_IDLE_DEBOUNCE_SEC:-1}"
HOLD_POLL_SEC="${APPROVE_HOLD_POLL_SEC:-0.08}"   # grace granularity between passes
HOLD_POLLS="${APPROVE_HOLD_POLLS:-3}"            # ~240ms of grace after each pass
HOLD_MAX_SEC="${APPROVE_HOLD_MAX_SEC:-60}"       # backstop for a wedged key

if ! take_lock "$LOCK" $((HOLD_MAX_SEC + 10)); then
  : > "$REPEAT" 2>/dev/null || true
  exit 0
fi
RESULTS=""
trap '[ -n "$RESULTS" ] && rm -rf "$RESULTS"; rm -rf "$LOCK"; true' EXIT HUP INT TERM

if [ -e "$STAMP" ] && [ $(( $(date +%s) - $(file_mtime "$STAMP") )) -lt "$IDLE_DEBOUNCE_SEC" ]; then
  exit 0
fi
RESULTS=$(mktemp -d "${TMPDIR:-/tmp}/herdr-approve-all.XXXXXX")

# One pass over the fleet. Blocked (red) panes are ordered first and send keys
# immediately; working/idle panes are checked via a single visible-screen read.
approved=0
stuck=0
sweep_once() {
  rm -rf "${RESULTS:?}"/*
  local n=0 f pane agent status _rest
  while read -r pane agent status _rest; do
    [ -n "$pane" ] || continue
    [ "${status:-}" = "?" ] && status=""
    n=$((n + 1))
    (
      lock=$(pane_lock_path "$pane")
      take_lock "$lock" 15 || exit 0
      trap 'rmdir "$lock" 2>/dev/null || true' EXIT HUP INT TERM
      approve_pane "$pane" "$agent" "${status:-}" > "$RESULTS/$n"
    ) &
  done << EOF
$(list_sorted_agents)
EOF
  wait
  for f in "$RESULTS"/*; do
    [ -e "$f" ] || continue
    case "$(cat "$f")" in
      1) approved=$((approved + 1)) ;;
      0) stuck=$((stuck + 1)) ;;
      *) ;;  # "-": pane had nothing pending
    esac
  done
}

started=$(date +%s)
while :; do
  sweep_once
  held=0
  i=0
  while [ "$i" -lt "$HOLD_POLLS" ]; do
    if [ -e "$REPEAT" ]; then
      rm -f "$REPEAT"
      held=1
      break
    fi
    sleep "$HOLD_POLL_SEC"
    i=$((i + 1))
  done
  [ "$held" -eq 1 ] || break
  [ $(( $(date +%s) - started )) -lt "$HOLD_MAX_SEC" ] || break
done

if [ "$approved" -eq 0 ] && [ "$stuck" -eq 0 ]; then
  : > "$STAMP"
  exit 0
fi

s=""
[ "$approved" -ne 1 ] && s="s"
msg="Approved $approved agent$s"
[ "$stuck" -gt 0 ] && msg="$msg · $stuck still blocked"
run_herdr notification show "$msg" --sound none >/dev/null 2>&1 || true
