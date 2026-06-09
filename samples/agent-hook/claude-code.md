# Arming TRP from a Claude Code hook

This cookbook shows how to make a coding agent resumable across terminal restarts
using the [Terminal Resume Protocol](https://github.com/Otty-sh/osc-88) (OSC 88).
The idea generalises to any agent with a `--resume`-style flag (Codex, OpenCode, …);
[Claude Code hooks](https://docs.claude.com/en/docs/claude-code/hooks) are used here
as a concrete example.

## The plan

- **On session start**, arm a relaunch that resumes *this* session:
  `claude --resume <session-id>`. If the terminal later cold-restarts, it re-runs
  that command and you land back in the conversation.
- **On a clean session end**, clear the spec so a deliberate exit is not resurrected.
  (If the process dies without the clean-exit hook firing — a crash, a reboot — the
  spec stays armed, which is exactly when you *want* to be resumed.)

Because `cmd` is the verification token, we arm `cmd=claude` and put the resume
flags in `args`. A conforming terminal verifies that a process whose `argv[0]`
basename is `claude` was actually running before it trusts the spec, then relaunches
`claude --resume <id>`.

## Emitting the sequence

Use the POSIX-sh emitter from this repo (`samples/shell/trp.sh`). It base64-encodes
values, writes to `/dev/tty`, and wraps for tmux/Zellij. The hook just sources it
and calls `trp_arm` / `trp_clear`.

### SessionStart hook — arm the resume

`SessionStart` runs when a session begins (or resumes). Claude Code passes the hook
JSON on stdin, including the session id; read it with whatever JSON tool you have
(`jq` shown here).

```sh
#!/bin/sh
# .claude/hooks/trp-arm.sh — arm "claude --resume <session-id>"
. "$HOME/.config/trp/trp.sh"   # the emitter from samples/shell/trp.sh

# Claude Code delivers the hook payload as JSON on stdin.
payload=$(cat)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty')

[ -n "$session_id" ] || exit 0   # nothing to arm

# cmd = claude (the verifiable head); args = the resume invocation.
# Agents repaint their own TUI, so self_repaint = 1.
trp_arm "claude" "--resume $session_id" 1
```

Wire it up in `.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "sh .claude/hooks/trp-arm.sh" }
        ]
      }
    ]
  }
}
```

### Clean-exit hook — clear the resume

When the session ends cleanly, withdraw the spec. Use whichever lifecycle hook your
agent exposes for a clean shutdown (for Claude Code, the `Stop` hook fires when the
agent finishes responding; a `SessionEnd`-style hook, where available, is the most
precise place to clear).

```sh
#!/bin/sh
# .claude/hooks/trp-clear.sh — withdraw the armed spec on clean exit
. "$HOME/.config/trp/trp.sh"
trp_clear
```

```json
{
  "hooks": {
    "SessionEnd": [
      {
        "hooks": [
          { "type": "command", "command": "sh .claude/hooks/trp-clear.sh" }
        ]
      }
    ]
  }
}
```

> If your agent has no clean-exit hook, you can still arm on start and rely on the
> terminal's own resume UI (Undo / opt-out) to manage stale specs. Arming without
> clearing just means a deliberate quit is also offered for resume — slightly noisier,
> still safe.

## Why this is safe

The terminal never executes the armed command blindly. Per the
[spec's security model](https://github.com/Otty-sh/osc-88/blob/main/SPEC.md#6-security-normative):

- it verifies that a `claude` process was actually running in the pane before trusting
  the spec (so forged bytes from `cat`-ing a file can't arm anything);
- it only ever runs the binary named by `cmd` (`claude`) — `args` cannot re-target it;
- it surfaces the resume as a reversible, user-visible action (e.g. a toast with *Undo*).

So the worst an injected OSC 88 can do is nothing: with no matching live process, the
spec is dropped.

## Adapting to other agents

| Agent | `cmd` | `args` |
|---|---|---|
| Claude Code | `claude` | `--resume <session-id>` |
| Codex | `codex` | `resume <session-id>` *(check your CLI's resume syntax)* |
| OpenCode | `opencode` | the equivalent resume invocation |

Set `self_repaint=1` for all of them — agent TUIs redraw their own screen on launch,
so the terminal should skip its own visual restore for that pane.
