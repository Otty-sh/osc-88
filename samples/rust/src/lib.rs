//! Reference parser for the Terminal Resume Protocol (OSC 88).
//!
//! Spec: <https://github.com/Otty-sh/osc-88>
//!
//! This crate parses the **payload** of an `OSC 88` sequence — i.e. the bytes
//! *between* `OSC 88 ;` and the string terminator (`ST`). The caller is
//! responsible for OSC framing (stripping `ESC ] 88 ;` and the trailing `ST`,
//! and unwrapping any tmux/Zellij passthrough envelope); this parser only sees
//! the inner `<op> [ ; <key>=<value> ]...` body.
//!
//! ```
//! use trp_parse::{parse, Op};
//!
//! // "arm;cmd=bnZpbQ==;args=LVMgU2Vzc2lvbi52aW0=;self_repaint=1"
//! let spec = parse("arm;cmd=bnZpbQ==;args=LVMgU2Vzc2lvbi52aW0=;self_repaint=1").unwrap();
//! assert_eq!(spec.op, Op::Arm);
//! assert_eq!(spec.cmd.as_deref(), Some("nvim"));
//! assert_eq!(spec.args.as_deref(), Some("-S Session.vim"));
//! assert!(spec.self_repaint);
//! ```

use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;

/// The operation carried by the sequence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    /// Declare / fully replace this pane's resume spec. Requires `cmd`.
    Arm,
    /// Withdraw the spec (clean exit / no longer resumable).
    Clear,
    /// Capability probe: terminal should reply `supported`.
    Query,
    /// Any other (e.g. terminal reply ops like `supported`), preserved verbatim.
    Other(String),
}

/// A parsed OSC 88 payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumeSpec {
    pub op: Op,
    /// The relaunch head and verification token (required for `arm`).
    pub cmd: Option<String>,
    /// The relaunch tail, appended after `cmd`.
    pub args: Option<String>,
    /// `true` if the resumed program repaints its own screen.
    pub self_repaint: bool,
    /// Working directory for the relaunch.
    pub cwd: Option<String>,
    /// Hint for the restored tab title.
    pub title: Option<String>,
    /// Protocol version (`v` field; default 1).
    pub version: u32,
}

/// Errors produced while parsing an OSC 88 payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    /// The payload was empty (no op token).
    Empty,
    /// An `arm` op was missing its required `cmd` field.
    MissingCmd,
    /// A base64 value failed to decode, or decoded to invalid UTF-8.
    /// Carries the offending key.
    BadBase64(String),
    /// An integer field (`v`) was not a valid integer.
    BadInteger(String),
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ParseError::Empty => write!(f, "empty OSC 88 payload"),
            ParseError::MissingCmd => write!(f, "`arm` requires a `cmd` field"),
            ParseError::BadBase64(k) => write!(f, "field `{k}` is not valid base64(UTF-8)"),
            ParseError::BadInteger(k) => write!(f, "field `{k}` is not a valid integer"),
        }
    }
}

impl std::error::Error for ParseError {}

fn decode_b64(key: &str, value: &str) -> Result<String, ParseError> {
    let bytes = B64
        .decode(value.as_bytes())
        .map_err(|_| ParseError::BadBase64(key.to_string()))?;
    String::from_utf8(bytes).map_err(|_| ParseError::BadBase64(key.to_string()))
}

/// Parse an OSC 88 payload string (the bytes between `OSC 88 ;` and `ST`).
///
/// - Splits the payload on `;`. The first token is the op; the rest are
///   `key=value` fields, split on the **first** `=`.
/// - base64-decodes string-valued fields; literal fields (`self_repaint`, `v`)
///   are read as-is.
/// - Ignores unknown keys (forward-compatibility).
/// - Returns [`ParseError::MissingCmd`] if an `arm` op has no `cmd`.
pub fn parse(payload: &str) -> Result<ResumeSpec, ParseError> {
    let mut parts = payload.split(';');

    let op_token = parts.next().ok_or(ParseError::Empty)?;
    if op_token.is_empty() {
        return Err(ParseError::Empty);
    }
    let op = match op_token {
        "arm" => Op::Arm,
        "clear" => Op::Clear,
        "query" => Op::Query,
        other => Op::Other(other.to_string()),
    };

    let mut spec = ResumeSpec {
        op: op.clone(),
        cmd: None,
        args: None,
        self_repaint: false,
        cwd: None,
        title: None,
        version: 1,
    };

    for field in parts {
        if field.is_empty() {
            continue;
        }
        // Split on the FIRST '=' only; base64 padding ('=') stays in the value.
        let (key, value) = match field.split_once('=') {
            Some((k, v)) => (k, v),
            // A bare token with no '=' is not a valid field; ignore it.
            None => continue,
        };

        match key {
            "cmd" => spec.cmd = Some(decode_b64(key, value)?),
            "args" => spec.args = Some(decode_b64(key, value)?),
            "cwd" => spec.cwd = Some(decode_b64(key, value)?),
            "title" => spec.title = Some(decode_b64(key, value)?),
            "self_repaint" => spec.self_repaint = value == "1",
            "v" => {
                spec.version = value
                    .parse::<u32>()
                    .map_err(|_| ParseError::BadInteger(key.to_string()))?;
            }
            // Unknown fields MUST be ignored (forward-compatibility).
            _ => {}
        }
    }

    if spec.op == Op::Arm && spec.cmd.is_none() {
        return Err(ParseError::MissingCmd);
    }

    Ok(spec)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_arm_with_all_common_fields() {
        // cmd=nvim, args="-S Session.vim", self_repaint=1
        let spec =
            parse("arm;cmd=bnZpbQ==;args=LVMgU2Vzc2lvbi52aW0=;self_repaint=1").unwrap();
        assert_eq!(spec.op, Op::Arm);
        assert_eq!(spec.cmd.as_deref(), Some("nvim"));
        assert_eq!(spec.args.as_deref(), Some("-S Session.vim"));
        assert!(spec.self_repaint);
        assert_eq!(spec.version, 1);
    }

    #[test]
    fn parses_clear() {
        let spec = parse("clear").unwrap();
        assert_eq!(spec.op, Op::Clear);
        assert_eq!(spec.cmd, None);
        assert!(!spec.self_repaint);
    }

    #[test]
    fn ignores_unknown_fields() {
        // `frobnicate` is an unknown key and MUST be ignored, not error.
        let spec = parse("arm;cmd=c3No;frobnicate=Zm9v;v=2").unwrap();
        assert_eq!(spec.op, Op::Arm);
        assert_eq!(spec.cmd.as_deref(), Some("ssh"));
        assert_eq!(spec.version, 2);
    }

    #[test]
    fn arm_without_cmd_is_an_error() {
        assert_eq!(parse("arm;args=Zm9v"), Err(ParseError::MissingCmd));
    }

    #[test]
    fn bad_base64_reports_the_key() {
        // "!!!!" is not valid base64.
        match parse("arm;cmd=!!!!") {
            Err(ParseError::BadBase64(k)) => assert_eq!(k, "cmd"),
            other => panic!("expected BadBase64(cmd), got {other:?}"),
        }
    }
}
