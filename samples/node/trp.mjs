// trp.mjs — Node (ESM) reference emitter for the Terminal Resume Protocol (OSC 88).
//
// Spec: https://github.com/Otty-sh/osc-88
//
// Usage as a library:
//
//     import { arm, clear } from './trp.mjs';
//     arm('nvim', '-S Session.vim', { selfRepaint: true });
//     // ... on clean exit:
//     clear();
//
// Usage as a CLI:
//
//     node trp.mjs arm nvim "-S Session.vim" --self-repaint
//     node trp.mjs clear
//
// Behaviour:
//   * Values are base64-encoded UTF-8 (so spaces, ';', '=', quotes are safe on the wire).
//   * The sequence is written to /dev/tty (the controlling terminal), NOT stdout,
//     because stdout is often captured by a parent (an agent runner, a shell job).
//   * If /dev/tty cannot be opened, the call is a silent no-op.
//   * Inside tmux (process.env.TMUX) or Zellij (process.env.ZELLIJ) the bytes are
//     wrapped in the multiplexer's passthrough envelope so they reach the outer terminal.

import fs from 'node:fs';

const ESC = '\x1b';
const OSC = ESC + ']'; // ESC ]
const ST = ESC + '\\'; // ESC \  (preferred string terminator)

function b64(s) {
  return Buffer.from(String(s), 'utf8').toString('base64');
}

// Wrap a fully-framed escape sequence in the tmux/Zellij passthrough envelope
// when running inside a multiplexer. Both use the same DCS envelope:
//   ESC P tmux; <payload with every ESC doubled> ESC \
function wrapForMultiplexer(seq) {
  if (process.env.TMUX || process.env.ZELLIJ) {
    const inner = seq.replaceAll(ESC, ESC + ESC);
    return `${ESC}Ptmux;${inner}${ST}`;
  }
  return seq;
}

// Write the OSC body (the part after "ESC ]" and before ST) to the controlling tty.
// Silent no-op if /dev/tty cannot be opened (e.g. no controlling terminal).
function emit(body) {
  const seq = wrapForMultiplexer(`${OSC}${body}${ST}`);
  let fd;
  try {
    fd = fs.openSync('/dev/tty', 'w');
  } catch {
    return; // no controlling tty -> nothing to talk to
  }
  try {
    fs.writeSync(fd, seq);
  } catch {
    // ignore write errors (tty went away)
  } finally {
    try {
      fs.closeSync(fd);
    } catch {
      /* ignore */
    }
  }
}

/**
 * Arm a resume spec.
 * @param {string} cmd  - the program head, also the verification token (required).
 * @param {string} [args] - everything after cmd.
 * @param {object} [opts]
 * @param {boolean} [opts.selfRepaint] - program redraws its own screen on resume.
 * @param {string} [opts.cwd] - working directory for the relaunch.
 * @param {string} [opts.title] - hint for the restored tab title.
 */
export function arm(cmd, args, opts = {}) {
  if (!cmd) throw new Error('trp.arm: cmd is required');

  const parts = ['88', 'arm', `cmd=${b64(cmd)}`];
  if (args) parts.push(`args=${b64(args)}`);
  if (opts.selfRepaint) parts.push('self_repaint=1'); // literal, not base64
  if (opts.cwd) parts.push(`cwd=${b64(opts.cwd)}`);
  if (opts.title) parts.push(`title=${b64(opts.title)}`);

  emit(parts.join(';'));
}

/** Withdraw the armed spec (call on clean exit). */
export function clear() {
  emit('88;clear');
}

// CLI when run directly: `node trp.mjs ...`
const invokedDirectly =
  process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href;

if (invokedDirectly) {
  const [, , sub, ...rest] = process.argv;
  if (sub === 'arm') {
    const positional = rest.filter((a) => a !== '--self-repaint');
    const selfRepaint = rest.includes('--self-repaint');
    const [cmd, args] = positional;
    if (!cmd) {
      process.stderr.write('usage: node trp.mjs arm <cmd> [args] [--self-repaint]\n');
      process.exit(2);
    }
    arm(cmd, args, { selfRepaint });
  } else if (sub === 'clear') {
    clear();
  } else {
    process.stderr.write('usage: node trp.mjs {arm <cmd> [args] [--self-repaint] | clear}\n');
    process.exit(2);
  }
}
