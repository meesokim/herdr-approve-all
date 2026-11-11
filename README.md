# herdr-approve-all

This fork adds native Windows PowerShell support and enhanced prompt/error
recovery for Ubuntu, macOS, and Windows to
[RenKoya1/herdr-approve-all](https://github.com/RenKoya1/herdr-approve-all).

A [herdr](https://herdr.dev) plugin that approves every blocked agent at once —
or automatically, the moment one blocks.

When you run a fleet of coding agents (Claude Code, Codex, Gemini CLI,
Antigravity `agy`, ...), permission prompts pile up and you end up pressing
**Yes** pane by pane. This plugin sends the confirm key to every waiting pane,
accepting the highlighted default option (usually **Yes**) in one keystroke —
or with zero keystrokes in auto mode — then checks each pane actually moved on
and answers whatever queued up behind it.

Works with any agent herdr detects; the confirm key defaults to `Enter`, which
accepts the highlighted default in Claude Code, Codex, Gemini CLI, Antigravity
(`agy`), and the rest of herdr's supported agents. When a subagent approval
banner is shown (`needs approval for ...` / `ctrl+k approve · alt+j manage`),
the plugin sends `ctrl+k`. When an agent stops on transient server or stream
errors (`There was a network issue connecting to the server, please try again.`
or `agent executor error: ... stream reading error: stream idle timeout ... context deadline exceeded`),
the plugin automatically submits `continue` to resume the interrupted turn.

## Install

```sh
herdr plugin install meesokim/herdr-approve-all
```

The default `main` branch includes both the Unix (`bash`) and Windows
(`powershell.exe`) implementations. The plugin ID remains
**`renkoya1.approve-all`** on every platform; installing from this fork does not
change the action prefix to `meesokim`.

## Windows quick start

Use native Windows Herdr with Git and Windows PowerShell (`powershell.exe`)
available on `PATH`. Bash, WSL, jq, and Python are not required on Windows.
See [Herdr's Windows installation guide](https://herdr.dev/docs/windows-beta/)
if Herdr is not installed yet. Windows behavior has been verified with Herdr
`0.9.4-preview.2026-10-14`.

Run the following in PowerShell or any shell on Windows, Linux, or macOS to
install, enable the plugin, and turn on automatic approval (the action IDs are
identical across Windows, Linux, and macOS):

```powershell
herdr plugin install meesokim/herdr-approve-all --yes
herdr plugin enable renkoya1.approve-all
herdr plugin action invoke renkoya1.approve-all.auto-on
```

Auto mode approves every pending prompt in every agent pane, including requests
to run destructive commands. Enable it only when you intend to approve all of
them. The ON toggle persists across Herdr restarts.

To turn automatic approval off (Windows, Linux, macOS):

```powershell
herdr plugin action invoke renkoya1.approve-all.auto-off
```

For a single manual sweep (Windows, Linux, macOS):

```powershell
herdr plugin action invoke renkoya1.approve-all.approve-blocked
```

Internally, `scripts/dispatch` (Unix) and `scripts/dispatch.cmd` (Windows)
route each action to the native OS implementation automatically. Legacy
`-windows` action IDs (`auto-on-windows`, `auto-off-windows`,
`approve-blocked-windows`) also remain available as aliases on Windows.

### Windows keybinding

Add this binding to `%APPDATA%\herdr\config.toml` (PowerShell path:
`$env:APPDATA\herdr\config.toml`):

```toml
[[keys.command]]
key = "prefix+y"
type = "plugin_action"
command = "renkoya1.approve-all.approve-blocked"
```

Then reload the configuration:

```powershell
herdr server reload-config
```

Press your configured Herdr prefix, then `y`, to run one sweep. Reloading config
is only needed after editing the keybinding; automatic approval runs continuously
once enabled. See [Herdr configuration](https://herdr.dev/docs/configuration/)
for config-path overrides and prefix settings.

### Auto-mode monitor and troubleshooting (Ubuntu, macOS, and Windows)

Enabling auto mode (`auto-on` on Linux/macOS or `auto-on-windows` on Windows)
starts a background monitor that rechecks the fleet every `APPROVE_AUTO_POLL_SEC`
seconds (default `0.3`), prioritizing `blocked` (red) panes first and then
inspecting `working` (green) and `idle` panes via a single visible-screen read.
This ensures prompts that never emit a `blocked` transition (such as `agy`
sandbox-bypass prompts, outside-workspace file access prompts, or transient
network errors requiring `continue`) are handled automatically on both Ubuntu
and Windows. Startup hooks restore the monitor when Herdr starts with the
persisted toggle enabled, and status-change events restart it if needed.

If automatic approval does not continue, invoke `auto-on` (Linux/macOS) or
`auto-on-windows` (Windows) again to start the monitor, then inspect plugin
status and logs:

```sh
herdr plugin list
herdr plugin action list --plugin renkoya1.approve-all
herdr plugin log list --plugin renkoya1.approve-all --limit 10
herdr agent list
```

### Local development instead of GitHub installation

```powershell
git clone https://github.com/meesokim/herdr-approve-all.git
herdr plugin link .\herdr-approve-all --enabled
```

Enable auto mode with `auto-on` (Linux/macOS) or `auto-on-windows` (Windows)
after linking.

## Manual sweep (Linux/macOS)

Bind the sweep to a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "ctrl+enter"
type = "plugin_action"
command = "renkoya1.approve-all.approve-blocked"
```

> `ctrl+enter` only reaches herdr if your terminal distinguishes it from plain
> `Enter` (e.g. Ghostty / Kitty with the kitty keyboard protocol). If it does
> not, bind a prefix chord instead, e.g. `key = "prefix+y"`.

Reload the config after editing: `herdr server reload-config`

Or invoke from the CLI:

```sh
herdr plugin action invoke renkoya1.approve-all.approve-blocked
```

A toast reports how many agents were **verified** approved, plus how many are
still blocked after the sweep gave up on them.

## Auto-approve mode (Linux/macOS)

Approve every prompt automatically — no keypress at all:

```sh
herdr plugin action invoke renkoya1.approve-all.auto-on
herdr plugin action invoke renkoya1.approve-all.auto-off
```

The plugin subscribes to agent status changes (`blocked` panes get `Enter`
immediately without an extra status query) and also runs a lightweight
background monitor (`scripts/auto-toggle.sh monitor`) so prompts whose status
remains `working`/`idle` or network errors requiring `continue` are handled
automatically. The toggle persists across restarts.

**This is the YOLO switch.** It approves *every* prompt in *every* pane,
including "run this destructive command?". Turn it on only when you'd answer
Yes to anything your fleet asks.

## Per-agent confirm keys

`Enter` is right for every agent we know of. If some agent needs a different
sequence, create `keys.conf` in the plugin config dir
(`herdr plugin config-dir renkoya1.approve-all`) with one line per agent:

```
codex=y enter
```

Key names follow `herdr agent send-keys` (e.g. `enter`, `esc`, `y`).

## Stacked prompts

A pane rarely asks once. A fleet of subagents queues several permission prompts
behind each other, and herdr reports `blocked` -> `blocked` across them: the
status never changes, so no new event fires and a single confirm key clears only
the first one.

So the sweep does not fire and forget. Per pane it sends the confirm key, waits
for the pane to leave `blocked`, then looks again — up to `APPROVE_MAX_SENDS`
(5) prompts per run. Auto mode runs the same drain, which is what makes it
survive a burst.

## Which panes get swept

Every agent pane is a candidate, not only the ones herdr reports as `blocked`.
herdr derives that status by scraping the terminal, and a live prompt can lose
to a higher-priority detection rule (a spinner in the OSC title, the composer's
own idle rule) — leaving a pane that is visibly waiting reported as
`working`/`idle`.

The fallback matches the active visible screen (while ignoring scrollback
history), supporting classic `esc to cancel` dialogs, `agy` permission prompts
(`> 1. Yes, run command`, `> 1. Yes, allow access`, sandbox bypass,
outside-workspace access), `ctrl+k` subagent approval banners, and submitting
`continue` on transient network or stream idle timeout error screens.
Antigravity file dialogs (`Accept this file edit?` / `> 1. Yes, accept this change`,
and `Allow creation of this file?`) and `Run this command?` / `> 1. Yes, run command`
ignore Enter, so the plugin sends `1`.
Set `APPROVE_SCRAPE_FALLBACK=0` to trust herdr's status alone.

## Hold the key to keep approving

Auto-repeat is used rather than fought. **Hold the key down and the sweep stays
alive**, re-checking the fleet every ~240ms, so prompts that appear while you
are still holding get approved as they arrive. Let go and it stops.

## Tuning

Env vars, read by both the sweep and the auto handler:

| Var | Default | Meaning |
| --- | --- | --- |
| `APPROVE_MAX_SENDS` | `5` | confirm keys per pane, per pass |
| `APPROVE_LEAVE_TIMEOUT_MS` | `1200` | how long to wait for a pane to leave `blocked` |
| `APPROVE_SETTLE_SEC` | `0.2` (`0.25` Win) | pause before re-checking, so a queued prompt or redraw can paint |
| `APPROVE_SCRAPE_FALLBACK` | `1` | also sweep panes whose live prompt herdr missed |
| `APPROVE_IDLE_DEBOUNCE_SEC` | `1` | window after an empty sweep |
| `APPROVE_HOLD_POLL_SEC` | `0.08` | hold-detection granularity |
| `APPROVE_HOLD_POLLS` | `3` | grace windows before a hold is considered released |
| `APPROVE_HOLD_MAX_SEC` | `60` | backstop: longest a single hold keeps sweeping |
| `APPROVE_AUTO_POLL_SEC` | `0.3` | auto monitor pause between fleet checks (minimum `0.1`) |
| `APPROVE_CMD_TIMEOUT_MS` / `APPROVE_CMD_TIMEOUT_SEC` | `4000` / `4` | timeout per `herdr` CLI call |
| `APPROVE_CONTINUE_COOLDOWN_SEC` | `4` | per-pane cooldown between automatic `continue` submissions |

## Verification

- **Linux / macOS (Ubuntu)**: Run `bash tests/smoke.sh`
- **Windows**: Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows-smoke.ps1`

## Requirements

- herdr ≥ 0.7.4
- macOS / Linux: `bash` on PATH, plus `jq` (fast path) or `python3` (fallback)
- Windows: Windows PowerShell (`powershell.exe`); Herdr's Windows plugin support
  may depend on the installed Herdr release.

## License

MIT
