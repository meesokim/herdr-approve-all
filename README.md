# herdr-approve-all

A [herdr](https://herdr.dev) plugin that approves every blocked agent at once —
or automatically, the moment one blocks.

When you run a fleet of coding agents (Claude Code, Codex, Gemini CLI, ...),
permission prompts pile up and you end up pressing **Yes** pane by pane. This
plugin sends the confirm key to every pane whose agent is in the `blocked`
state, accepting the highlighted default option (usually **Yes**) in one
keystroke — or with zero keystrokes in auto mode.

Works with any agent herdr detects; the confirm key defaults to `Enter`, which
accepts the highlighted default in Claude Code, Codex, Gemini CLI, and the rest
of herdr's supported agents.

## Install

```sh
herdr plugin install RenKoya1/herdr-approve-all
```

## Manual sweep

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

A toast reports how many agents were approved. Key auto-repeat is debounced,
so holding the key down doesn't flood the server.

## Auto-approve mode

Approve every prompt the instant an agent blocks — no keypress at all:

```sh
herdr plugin action invoke renkoya1.approve-all.auto-on
herdr plugin action invoke renkoya1.approve-all.auto-off
```

The plugin subscribes to agent status changes; when a pane turns `blocked`, it
sends the confirm key immediately. The toggle persists across restarts (it's a
marker file in the plugin config dir).

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

## What it does (and doesn't)

- Manual sweep targets panes blocked at the moment you invoke it; panes that
  block right after need another press (or auto mode).
- Sends the confirm key, i.e. accepts whatever option is highlighted. For
  permission prompts that is **Yes**; for other blocking dialogs (question
  cards, plan approvals, trust dialogs) it picks the default option.

**Caution**: this is indiscriminate by design. If a pending prompt is asking to
run a destructive command, this approves it too. Glance at your panes before
pressing the key — or accept the risk knowingly with auto mode.

## Requirements

- herdr ≥ 0.7.4
- `bash` on PATH, plus `jq` (fast path) or `python3` (fallback) — macOS / Linux

## License

MIT
