# herdr-approve-all

A [herdr](https://herdr.dev) plugin that approves every blocked agent at once.

When you run a fleet of Claude Code / Codex / other agent sessions, permission
prompts pile up and you end up pressing **Yes** pane by pane. This plugin sends
`Enter` to every pane whose agent is in the `blocked` state, accepting the
highlighted default option (usually **1. Yes**) on each pending prompt in one
keystroke.

## Install

```sh
herdr plugin install RenKoya1/herdr-approve-all
```

## Usage

Invoke the action from the CLI:

```sh
herdr plugin action invoke renkoya1.approve-all.approve-blocked
```

Or bind it to a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "ctrl+enter"
type = "plugin_action"
command = "renkoya1.approve-all.approve-blocked"
```

> `ctrl+enter` only reaches herdr if your terminal distinguishes it from plain
> `Enter` (e.g. Ghostty / Kitty with the kitty keyboard protocol). If it does
> not, bind a prefix chord instead, e.g. `key = "prefix+y"`.

Reload the config after editing:

```sh
herdr server reload-config
```

## What it does (and doesn't)

- Targets only panes whose agent status is `blocked` at the moment you invoke it.
- Sends a single `Enter`, i.e. accepts whatever option is highlighted. For
  permission prompts that is **Yes**; for other blocking dialogs (question
  cards, plan approvals, trust dialogs) it picks the default option.
- Panes that become blocked right after the sweep need another invocation.

**Caution**: this is indiscriminate by design. If one of the pending prompts is
asking to run a destructive command, this approves it too. Glance at your panes
before pressing the key.

## Requirements

- herdr ≥ 0.7.4
- `bash` and `python3` on PATH (macOS / Linux)

## License

MIT
