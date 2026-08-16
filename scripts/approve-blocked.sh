#!/usr/bin/env bash
# Approve every waiting agent pane (any agent: claude, codex, gemini, ...) by
# sending its confirm key, accepting the highlighted default (Yes) prompt, then
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
# a deliberate re-press is always honoured immediately. (Before 0.3.0 a flat 10s
# window applied to every sweep, which silently ate exactly the presses that
# mattered: the ones aimed at the next prompt in a burst.)
LOCK="${TMPDIR:-/tmp}/herdr-approve-all.lock"
REPEAT="$LOCK/repeat"
STAMP="${TMPDIR:-/tmp}/herdr-approve-all.empty-stamp"
IDLE_DEBOUNCE_SEC="${APPROVE_IDLE_DEBOUNCE_SEC:-1}"
HOLD_POLL_SEC="${APPROVE_HOLD_POLL_SEC:-0.08}"   # grace granularity between passes
HOLD_POLLS="${APPROVE_HOLD_POLLS:-3}"            # ~240ms of grace after each pass
HOLD_MAX_SEC="${APPROVE_HOLD_MAX_SEC:-60}"       # backstop for a wedged key

# Stale-lock takeover is sized just past the longest a sweeper can live, so a
# killed run costs one press, not two minutes of dead keypresses.
if ! take_lock "$LOCK" $((HOLD_MAX_SEC + 10)); then
  # A sweep is already running: register this repeat and get out of its way.
  : > "$REPEAT" 2>/dev/null || true
  exit 0
fi
RESULTS=""
trap '[ -n "$RESULTS" ] && rm -rf "$RESULTS"; rm -rf "$LOCK"; true' EXIT HUP INT TERM

if [ -e "$STAMP" ] && [ $(( $(date +%s) - $(file_mtime "$STAMP") )) -lt "$IDLE_DEBOUNCE_SEC" ]; then
  exit 0
fi
RESULTS=$(mktemp -d "${TMPDIR:-/tmp}/herdr-approve-all.XXXXXX")

# One pass over the fleet. Every agent pane is a candidate, not just the ones
# herdr calls blocked: needs_approval() also catches a pane whose live prompt
# lost to a higher-priority detection rule (see prompt_visible in lib.sh).
approved=0
stuck=0
sweep_once() {
  rm -rf "${RESULTS:?}"/*
  local n=0 f
  while read -r pane agent; do
    [ -n "$pane" ] || continue
    n=$((n + 1))
    (
      lock=$(pane_lock_path "$pane")
      take_lock "$lock" 60 || exit 0
      trap 'rmdir "$lock" 2>/dev/null || true' EXIT HUP INT TERM
      approve_pane "$pane" "$agent" > "$RESULTS/$n"
    ) &
  done << EOF
$("$HERDR" agent list | json_eval \
  '.result.agents[] | "\(.pane_id) \(.agent // "unknown")"' \
  'for a in d.get("result", {}).get("agents", []):
    print(a["pane_id"], a.get("agent", "unknown"))')
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
  # Still held? Repeats land continuously while the key is down, so a short
  # grace window is enough to tell "held" from "released".
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
"$HERDR" notification show "$msg" --sound none >/dev/null 2>&1 || true
