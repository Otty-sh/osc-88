#!/bin/sh
# trp.sh — POSIX-sh reference emitter for the Terminal Resume Protocol (OSC 88).
#
# Spec: https://github.com/Otty-sh/osc-88
#
# Source this file, then call:
#
#     trp_arm <cmd> [args] [self_repaint]    # declare how to relaunch me
#     trp_clear                              # withdraw the declaration (clean exit)
#
# Examples:
#
#     . ./trp.sh
#     trp_arm nvim "-S Session.vim" 1        # arm "nvim -S Session.vim", self-repainting
#     trp_arm ssh  "prod-bastion"            # arm "ssh prod-bastion", no self-repaint
#     trp_clear                              # on clean exit
#
# Behaviour:
#   * Values are base64-encoded UTF-8 (so spaces, ';', '=', quotes are safe on the wire).
#   * The sequence is written to /dev/tty (the controlling terminal), NOT stdout,
#     because stdout is often captured by a parent (an agent runner, a shell job).
#   * If there is no controlling tty, the call is a silent no-op.
#   * Inside tmux ($TMUX) or Zellij ($ZELLIJ) the bytes are wrapped in the
#     multiplexer's passthrough envelope so they reach the outer terminal.
#
# This file is intentionally dependency-free (only base64 + printf).

# Base64-encode stdin with no line wrapping. GNU base64 needs -w0; BSD/macOS
# base64 has no -w flag and never wraps, so fall back to a tr-based de-wrap.
_trp_b64() {
	if printf '' | base64 -w0 >/dev/null 2>&1; then
		base64 -w0
	else
		base64 | tr -d '\n'
	fi
}

# Write a raw OSC 88 payload (already framed as "88;...") to the controlling tty,
# wrapping in the tmux/Zellij passthrough envelope when needed.
#
# $1 = the OSC body, beginning after "ESC ]" and ending before ST, e.g.
#      "88;clear" or "88;arm;cmd=...".
_trp_emit() {
	# No controlling tty -> nothing to talk to. Silent no-op.
	[ -e /dev/tty ] || return 0
	{ : >/dev/tty; } 2>/dev/null || return 0

	# ESC and ST. OSC = ESC ] ; ST = ESC \ (preferred).
	esc=$(printf '\033')
	st=$(printf '\033\\')

	seq="${esc}]$1${st}"

	if [ -n "${TMUX:-}" ]; then
		# tmux passthrough: ESC P tmux; <ESC doubled> ... ESC \
		# Every ESC inside the wrapped payload must be doubled.
		inner=$(printf '%s' "$seq" | sed "s/${esc}/${esc}${esc}/g")
		printf '%sPtmux;%s%s' "$esc" "$inner" "$st" >/dev/tty 2>/dev/null
	elif [ -n "${ZELLIJ:-}" ]; then
		# Zellij uses the same DCS passthrough envelope as tmux.
		inner=$(printf '%s' "$seq" | sed "s/${esc}/${esc}${esc}/g")
		printf '%sPtmux;%s%s' "$esc" "$inner" "$st" >/dev/tty 2>/dev/null
	else
		printf '%s' "$seq" >/dev/tty 2>/dev/null
	fi
}

# trp_arm <cmd> [args] [self_repaint]
#   cmd          : the program head, also the verification token (required)
#   args         : everything after cmd (optional; default empty)
#   self_repaint : 1 if the program redraws its own screen on resume (optional; default 0)
trp_arm() {
	[ -n "$1" ] || { echo "trp_arm: cmd is required" >&2; return 2; }

	_cmd=$(printf '%s' "$1" | _trp_b64)
	body="88;arm;cmd=${_cmd}"

	if [ -n "${2:-}" ]; then
		_args=$(printf '%s' "$2" | _trp_b64)
		body="${body};args=${_args}"
	fi

	# self_repaint is a literal 0/1 on the wire (not base64).
	case "${3:-0}" in
		1) body="${body};self_repaint=1" ;;
		*) : ;; # default 0 — omit
	esac

	_trp_emit "$body"
}

# trp_clear — withdraw the armed spec (call on clean exit).
trp_clear() {
	_trp_emit "88;clear"
}

# If executed directly (not sourced), act as a tiny CLI.
#   trp.sh arm   <cmd> [args] [self_repaint]
#   trp.sh clear
case "${0##*/}" in
	trp.sh)
		case "${1:-}" in
			arm)   shift; trp_arm "$@" ;;
			clear) trp_clear ;;
			*)     echo "usage: trp.sh {arm <cmd> [args] [self_repaint] | clear}" >&2; exit 2 ;;
		esac
		;;
esac
