# Terminal Resume Protocol (TRP) — OSC 88

**Status: Proposal (v1)**

The **Terminal Resume Protocol (TRP)** is a vendor-neutral [OSC](https://en.wikipedia.org/wiki/ANSI_escape_code#OSC_(Operating_System_Command)) escape sequence (`OSC 88`) that lets a long-lived program declare — once — *how it would like to be relaunched*. The terminal stores that declaration and, on a cold restart (crash, reboot, app upgrade, quit-and-reopen), re-runs it. One small escape sequence, understood by any terminal, replaces a pile of per-app special cases.

TRP is **not** Otty-specific. This repository is its open, canonical home so any terminal can adopt the same command number and wire format. See [SPEC.md](SPEC.md) for the normative specification.

## Why

When user start a work with command `claude`, you cannot continue or recover the work by re-running the command `claude`, you need to run `cluade --resume XXXX`, but the terminal does not have such info, so it is hard for terminal to resume user's work on re-start. That is the issue this OSC wants to solve, in detail:

When a terminal restarts, every long-lived program inside it dies. A terminal *can* restore the visual scrollback from a log, but it cannot bring the **program** back, because it has no idea how that program was launched or how to re-enter its prior state.

Today each terminal solves this with bespoke, terminal-specific machinery: iTerm2 keeps jobs alive in long-running *process servers*; tmux / Zellij run a persistent *server* you re-attach to. None of it is portable, and none of it works for an arbitrary program (`nvim -S session.vim`, an SSH session, a coding agent with a `--resume` flag) that isn't a multiplexer.

TRP flips the responsibility: instead of the terminal *guessing* how to revive a program, **the program declares — once — how it would like to be relaunched.** It is deliberately a **declarative, one-way** protocol (the program announces state; the terminal acts on its own schedule). It is *not* an RPC channel — for interactive editor↔agent control, see [ACP](https://agentclientprotocol.com/).

## Demo scenarios

- **Editor sessions** — a Neovim/Helix plugin arms `nvim -S Session.vim`. After a reboot the file reopens at the same buffers, on its own, with no replay garble.
- **Remote shells** — an SSH wrapper arms `ssh prod-bastion`; the connection is re-established in the restored pane instead of leaving a dead prompt.
- **Multiplexers** — tmux arms `tmux new -A -s main` (attach-or-create); restoring the window re-attaches the live session.
- **Coding agents** — a Claude Code / Codex / OpenCode hook arms the agent's own `--resume` invocation, so a restored terminal drops you back into the session.
- **Long-running TUIs** — `lazygit`, `k9s`, a REPL — anything that can describe its own relaunch can opt in.

## Quick start — for a TUI / program

Emit one sequence when your program starts. Values are base64-encoded UTF-8.

```sh
# "arm" — declare how to relaunch me.
#   cmd  = the program head (also the verification token)
#   args = everything after it
printf '\e]88;arm;cmd=%s;args=%s;self_repaint=1\a' \
  "$(printf 'nvim'              | base64)" \
  "$(printf -- '-S Session.vim' | base64)"
```

When your program exits *cleanly*, withdraw the declaration so a deliberate quit is not resurrected:

```sh
printf '\e]88;clear\a'
```

A crash (no `clear`) leaves the declaration armed — which is exactly when you *want* to be resumed.

> **Write to the controlling tty.** Emit to `/dev/tty`, not stdout — stdout is often captured by a parent (an agent runner, a shell job). Inside tmux / Zellij, wrap the bytes in the multiplexer's passthrough envelope so they reach the outer terminal. The [samples](samples/) handle this for you.

## Quick start — for a terminal

To implement TRP in your terminal:

1. **Parse** `OSC 88`. Split the payload on `;`; `tokens[0]` is the op (`arm` / `clear`); the rest are `key=value` (split on the **first** `=`; values are base64). Ignore unknown keys (forward-compat) and ignore the whole sequence if you don't implement TRP.
2. **Store** the armed spec per pane. `arm` fully replaces the prior spec (idempotent, last-write-wins); `clear` removes it.
3. **Verify before persisting** (see [Security](#security)) — do *not* trust an armed command blindly.
4. **On cold restore**, re-execute `cmd` followed by `args` in `cwd`. If `self_repaint=1`, skip whatever visual restore you normally do for that pane (log replay, snapshot) — the program redraws itself, and doing both races and garbles the grid.
5. **Surface it** — show a user-visible, undoable indication that a command was resumed.

## Wire format

```
OSC 88 ; <op> [ ; <key>=<value> ]... ST
```

- `OSC` = `ESC ]`; `ST` = `ESC \` (preferred) or `BEL` (`\a`). `;` separates params.
- Values are **base64(UTF-8)** — commands contain spaces, quotes, `;`, `=` and non-ASCII; base64's alphabet excludes `;`, so it can never break the framing.
- `key=value` splits on the **first** `=` (trailing base64 `=` padding stays in the value).

| op | Meaning |
|---|---|
| `arm` | Declare / fully replace this pane's resume spec. Requires `cmd`. Idempotent. |
| `clear` | Withdraw the spec (clean exit / no longer resumable). |
| `query` *(optional)* | `OSC 88 ; query ST` → terminal replies `OSC 88 ; supported ; v=<max> ST`. |

**Fields for `arm`:** `cmd` (required, the relaunch head and verification token), `args` (the relaunch tail), `self_repaint` (`0`/`1`), `cwd`, `title`, `v` (protocol version). All values are base64(UTF-8); unknown fields are ignored. See [SPEC.md](SPEC.md#fields-for-arm) for the full table.

```sh
# nvim with a session file, self-repainting
printf '\e]88;arm;cmd=bnZpbQ==;args=LVMgU2Vzc2lvbi52aW0=;self_repaint=1\a'
# tmux attach-or-create (idempotent)
printf '\e]88;arm;cmd=dG11eA==;args=bmV3IC1BIC1zIG1haW4=;self_repaint=1\a'
# ssh, no self-repaint (terminal does its own visual restore)
printf '\e]88;arm;cmd=c3No;args=cHJvZC1iYXN0aW9u\a'
# clean exit — withdraw
printf '\e]88;clear\a'
```

## Security

TRP persists a command that a terminal will later **execute**, so it is designed to resist *escape-sequence injection without code execution* — crafted bytes that arrive via `cat`-ing a file, an upstream process's stdout, or `man` / `git log` rendering attacker-controlled text. (iTerm2, xterm and others have shipped CVEs for exactly this class.) It does **not** defend against an attacker who already has code execution in the pane — persisting a resume command is strictly weaker than what they already have.

A conforming terminal:

- **MUST NOT** execute a resumed command without a verification gate against the injection class above. The **recommended** mechanism is *process-identity verification*: before persisting, confirm a live process in the pane's process tree has an `argv[0]` basename equal to `basename(cmd)`.
- **MUST** execute only the binary named by `cmd` as the program head; `args` MUST NOT change which binary runs.
- **MUST** surface the resume as a user-visible, **reversible** action (e.g. a toast with *Undo*).
- **SHOULD** offer a per-user / per-binary opt-out (deny-list).

See [SPEC.md § Security](SPEC.md#security-normative) for the normative requirements and threat model.

## Samples

- [`samples/shell/trp.sh`](samples/shell/trp.sh) — POSIX-sh reference emitter (`trp_arm` / `trp_clear`).
- [`samples/node/trp.mjs`](samples/node/trp.mjs) — Node ESM emitter + CLI.
- [`samples/rust/`](samples/rust/) — reference parser crate (`cargo test`).
- [`samples/nvim/trp.lua`](samples/nvim/trp.lua) — copy-pasteable Neovim plugin.
- [`samples/agent-hook/claude-code.md`](samples/agent-hook/claude-code.md) — arming/clearing from a Claude Code hook.

## Reference implementation

Reference implementation: [Otty](https://otty.sh) — full docs at [doc.otty.sh/vt/osc/osc-88](https://doc.otty.sh/vt/osc/osc-88).

## License

[MIT](LICENSE).
