# Terminal Resume Protocol (TRP) — OSC 88 Specification

**Status: Proposal (v1)**

This document is the normative specification for the **Terminal Resume Protocol (TRP)**, a vendor-neutral [OSC](https://en.wikipedia.org/wiki/ANSI_escape_code#OSC_(Operating_System_Command)) escape sequence carried on OSC command number **88**.

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**, **SHOULD**, **SHOULD NOT**, **RECOMMENDED**, **MAY**, and **OPTIONAL** in this document are to be interpreted as described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119).

The reference implementation is [Otty](https://otty.sh). TRP is **not** Otty-specific; Otty is named only as the reference implementation.

## 1. Purpose

A program inside a terminal uses TRP to **declare how it would like to be relaunched** after the terminal restarts (crash, OS reboot, app upgrade, deliberate quit-and-reopen). The terminal stores that declaration on a per-pane basis and, on a cold restore, re-executes it.

TRP is **declarative and one-way**: the program announces intent; the terminal acts on its own schedule. TRP is **not** an RPC channel and has no request/response semantics beyond the OPTIONAL capability `query`.

## 2. Wire format

### 2.1 Grammar

```
sequence  = OSC "88" ";" op *( ";" field ) ST
op        = "arm" / "clear" / "query" / token        ; token = reply ops, e.g. "supported"
field     = key "=" value
key       = 1*( %x21-3C / %x3E-7E )                   ; any printable byte except ";" and "="
value     = *( base64-char )                          ; base64(UTF-8) of the logical value

OSC       = ESC "]"                                   ; %x1B %x5D
ST        = ESC "\" / BEL                              ; %x1B %x5C  (preferred) or %x07
```

- `OSC` is `ESC ]` (`0x1B 0x5D`). `ST` (string terminator) is `ESC \` (`0x1B 0x5C`, **preferred**) or `BEL` (`0x07`). A receiver **MUST** accept either terminator. An emitter **SHOULD** prefer `ESC \`.
- `;` (`0x3B`) separates the OSC command number, the op, and each field.
- The op is the first token after the command number.

### 2.2 Field encoding

- Each `field` is a `key=value` pair. The receiver **MUST** split on the **first** `=` only; any further `=` characters belong to the value (base64 padding ends in `=`).
- A `key` **MUST NOT** contain `;` or `=`.
- Every `value` is **base64(UTF-8)** of the logical string value, using the standard base64 alphabet (`A-Z a-z 0-9 + /`) with `=` padding. base64's alphabet excludes `;`, so an encoded value can never break the OSC framing. A receiver **MUST** base64-decode each value before use and **MUST** treat the decoded bytes as UTF-8.
- Integer-typed fields (e.g. `v`, `self_repaint`) are encoded as their **literal ASCII digits**, *not* base64 (see the field table for which fields are literal vs base64). This keeps the common `self_repaint=1` form readable on the wire and matches existing implementations.
- A receiver **MUST** ignore fields whose `key` it does not recognise (forward-compatibility).
- A receiver that does not implement TRP **MUST** ignore the entire `OSC 88` sequence.

## 3. Operations

| op | Direction | Meaning |
|---|---|---|
| `arm` | program → terminal | Declare / fully replace this pane's resume spec. **REQUIRES** `cmd`. Idempotent (last-write-wins). |
| `clear` | program → terminal | Withdraw the spec for this pane (clean exit / no longer resumable). |
| `query` | program → terminal | OPTIONAL. `OSC 88 ; query ST`. The terminal **SHOULD** reply (see 3.1). |
| `supported` | terminal → program | Reply to `query`: `OSC 88 ; supported ; v=<max> ST`, where `<max>` is the highest protocol version the terminal implements. |

- An `arm` op **MUST** carry a `cmd` field. A receiver **MUST** reject (ignore) an `arm` with no `cmd`.
- An `arm` **MUST** fully replace any previously armed spec for the pane (it is not a partial patch — see Open Questions).
- A `clear` op takes no fields; any present **MUST** be ignored.

### 3.1 Capability detection

TRP is **fire-and-forget by default**: a program **MAY** emit `arm`/`clear` unconditionally. A terminal that does not implement TRP ignores the bytes, and a terminal that does implement it stores the spec — neither path requires the program to detect support first.

For the cases where a program wants confirmation, the OPTIONAL `query` op provides it. A program emits `OSC 88 ; query ST`. A conforming terminal that implements `query` **SHOULD** reply with `OSC 88 ; supported ; v=<max> ST` on the same tty. A program **MUST NOT** block indefinitely waiting for a reply — absence of a reply means "unknown / treat as fire-and-forget", not "unsupported".

## 4. Fields (for `arm`)

| key | Required | Encoding | Type | Meaning |
|---|---|---|---|---|
| `cmd` | ✓ | base64 | string | The relaunch **head** and the verification token. Its basename **MUST** match the broadcasting process (see § Security). |
| `args` | — | base64 | string | The relaunch **tail**, appended after `cmd`. Absent = run `cmd` alone. |
| `self_repaint` | — | literal | `0` / `1` | `1` = the resumed program repaints its own screen; the terminal **SHOULD** skip its visual restore for this pane. Default `0`. |
| `cwd` | — | base64 | string | Working directory for the relaunch. Absent = the terminal's last-known cwd for the pane. |
| `title` | — | base64 | string | Hint for the restored tab title. Lower priority than [OSC 0/2](https://doc.otty.sh/vt/osc/osc-0-2). |
| `v` | — | literal | integer | Protocol version. Default `1`. |

Unknown fields **MUST** be ignored (§ 2.2).

### 4.1 The `cmd` / `args` trust boundary

`cmd` and `args` are split deliberately, and the split **is the trust boundary**:

- `cmd` is the *verifiable* token. Before a terminal trusts an armed spec it **MUST** prove that a process by that name was actually running in the pane (§ Security). Resume executes `cmd` as the program head, so **the executed binary is exactly the one that was verified**.
- `args` is the *unverified* tail. It is appended after `cmd` and flows through the relaunch unchanged. Because verification is anchored on `cmd`, `args` **MUST NOT** be able to change which binary runs (no shell metacharacters that re-target execution, no leading flags that turn `cmd` into a loader for another program; a terminal **MUST** execute `cmd` as `argv[0]` of the relaunch and treat `args` strictly as subsequent arguments).

Drawing this boundary on the wire — rather than shipping a single opaque command string — is what lets a terminal verify the dangerous part (which binary) while still allowing arbitrary, program-defined arguments.

## 5. Execution model

The execution model is **terminal-agnostic**: TRP says *what* to relaunch and *that* it should be verified and surfaced, not *how* a particular terminal spawns processes, restores panes, or stores state.

On a cold restore of a pane that has a verified armed spec, a conforming terminal:

1. **MUST** re-execute `cmd` as the program head with `args` as its subsequent arguments.
2. **MUST** run it in `cwd` if present, otherwise in the terminal's last-known cwd for that pane.
3. If `self_repaint=1`, **SHOULD** skip whatever visual restore it would normally perform for that pane (log replay, snapshot). Performing both races the program's own redraw and garbles the grid.
4. **MUST** surface the resume as a user-visible, reversible action (§ Security).
5. **MAY** apply `title` as the restored pane/tab title, at a priority below [OSC 0/2](https://doc.otty.sh/vt/osc/osc-0-2).

A terminal **MAY** choose *when* a restore happens (immediately on launch, on user confirmation, never if the user opted out) — TRP does not constrain the schedule.

## 6. Security (normative)

TRP persists a command that a terminal will later **execute**. It is designed to resist **escape-sequence injection without code execution** — crafted bytes that arrive via `cat`-ing a file, an upstream process's stdout, or `man` / `git log` rendering attacker-controlled text. iTerm2, xterm, and others have shipped CVEs for exactly this class of attack.

### 6.1 Threat model

- **In scope:** an attacker who can cause arbitrary bytes to be written to the terminal's input stream **without** executing code in the pane (the injection class above). TRP **MUST** prevent such an attacker from arming a spec that the terminal will later execute.
- **Out of scope:** an attacker who already has **code execution** in the pane. Persisting a resume command is strictly weaker than the capability such an attacker already holds, so defending against it is not a goal.

### 6.2 Requirements

A conforming terminal:

- **MUST NOT** execute a resumed command without a verification gate against the in-scope injection class.
- The **RECOMMENDED** verification mechanism is *process-identity verification*: before persisting an `arm`, confirm that a live process in the pane's process tree has an `argv[0]` whose basename equals `basename(cmd)`. A `cat` (or similar) emitting forged bytes cannot change its own `argv[0]` and exits before any verification tick observes it, so its forged spec is silently dropped. The spec mandates the *property* — "prove the arming program is, or was, the named binary" — **not** this exact mechanism; a terminal **MAY** satisfy it by other means that achieve the same property.
- **MUST** execute only the binary named by `cmd` as the program head; `args` **MUST NOT** change which binary runs (§ 4.1).
- **MUST** surface the resume as a user-visible, **reversible** action (for example, a toast with an *Undo* control).
- **SHOULD** offer a per-user and/or per-binary opt-out (a deny-list of commands that are never resumed).

In the reference implementation (Otty), the verification gate is a 1 Hz process reaper (the same one that powers agent detection); the user-visible reversible action is a 5-second *Resumed: … [Undo]* toast on restore.

## 7. OSC command number 88

The number **88** was verified to be unassigned as an OSC *command*. The only established use of "88" in terminal ecosystems is `xterm-88color` / `TERM=*-88color`, which is a **terminfo color-palette** concept (an 88-entry color cube, selected via [OSC 4](https://doc.otty.sh/vt/osc/osc-4)) — it is **not** an OSC command and does not occupy OSC command space. xterm's own dynamic/highlight color commands are OSC 10–19 (highlight is OSC 17 / OSC 19), not 88. No terminal emulator surveyed implements an OSC *command* 88.

The OSC command number for TRP **SHOULD** be coordinated through the community registry at [terminfo.dev/osc](https://terminfo.dev/osc) rather than being treated as unilaterally claimed. Until coordination concludes, `88` is the proposed number; implementations are encouraged to track this repository for changes.

## 8. Open questions

These are unresolved and **MAY** change before v1 is finalised:

- **`arm` replace vs a future `patch` op.** `arm` is currently full-replace (last-write-wins). A future `patch` op could update individual fields (e.g. bump `cwd` as the program changes directory) without re-sending the whole spec. Whether this is worth the added state machine is open.
- **Program-overridable `cwd`.** Today `cwd` is whatever the program armed, or the terminal's last-known pane cwd. It is open whether a program should be able to *pin* a cwd that the terminal must not override, versus the terminal always preferring its own freshest cwd.
- **`query` reply format vs DECRPM.** The reply is currently `OSC 88 ; supported ; v=<max> ST`. An alternative is a DECRPM-style (`CSI ? Ps ; Pm $ y`) report to align with how terminals report other mode states. The trade-off (OSC symmetry vs DEC-mode convention) is unresolved.

## 9. Versioning

The protocol version is carried in the `v` field (default `1`). A receiver **MUST** ignore fields and ops it does not understand, which allows additive evolution within a major version. A breaking change **MUST** increment `v`, and a terminal **SHOULD** advertise the highest version it supports via the `query`/`supported` exchange (§ 3.1).

## 10. References

- [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) — requirement keywords.
- [Otty TRP documentation](https://doc.otty.sh/vt/osc/osc-88) — reference implementation docs.
- [ACP](https://agentclientprotocol.com/) — the bidirectional agent/editor RPC protocol TRP is *not* (contrast).
- [terminfo.dev/osc](https://terminfo.dev/osc) — community OSC number registry.
