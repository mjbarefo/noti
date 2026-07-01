# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`noti` replaces Claude Code's terminal permission prompt with a macOS corner toast
(PreToolUse hook) and shows an end-of-turn summary toast (Stop hook). Two source
files: `noti` (Python 3, the policy engine + hook adapter + CLI) and
`bin/noti-toast.swift` (the NSPanel UI).

## Commands

- `./noti build` — compile the Swift binary (required after any .swift change)
- `./test.sh` — full test suite: policy decisions, rule round-trip, security
  regressions. Headless; never shows a toast. Run it after ANY change to `noti`.
- `./noti decide` — dry-run the policy on PreToolUse JSON from stdin (no toast)
- `NOTI_SNAPSHOT=/path.png ./bin/noti-toast ask|summary ...` — render a card to
  PNG without screen-recording permission (use for visual review; screenshots of
  live toasts come back as wallpaper-only)
- `NOTI_DEBUG=1` + `~/.config/noti/noti.log` — hook debugging
- `ruff check noti` — lint the Python (brew ruff or `./.venv/bin/ruff`; config in
  `ruff.toml`). The `noti` CLI has no `.py` extension, so name it explicitly.

## Live-install gotcha

The user's global `~/.claude/settings.json` hooks run `noti` **from this working
copy, in place**. Any edit to `noti` takes effect in the next Claude Code session
(and a broken edit degrades every session's permission flow — it fails open to
the terminal prompt, but still). Run `./test.sh` before leaving the file in a
broken state, and never leave `noti` unparseable between edits.

## Non-negotiable invariants

- **Never block the session.** Every hook entry point must exit 0 and emit no
  decision on any internal error. A noti bug must degrade to Claude's own
  permission flow, never to a hang or a spurious allow.
- **Deny rules are checked before everything** — before permission-mode
  short-circuits, allow rules, and safe-lists. Do not reorder `evaluate()`.
- **`make_rule` and `pattern_matches` must round-trip**: any rule noti mints must
  be matched by noti's own matcher (test.sh enforces this).
- **Stricter-than-Claude is the safe direction** for the rule matcher: an
  over-strict matcher costs an extra toast; an over-broad one silently
  auto-allows. E.g. a bare trailing `*` in a Bash rule is matched literally on
  purpose, and `make_rule` refuses to mint rules for commands ending in `*`.
- **Zero dependencies**: stdlib-only Python, AppKit-only Swift. Do not add
  packages, package managers, or build systems.
- The security regression tests in `test.sh` encode fixed vulnerabilities.
  Never weaken one to make a change pass; add new ones when fixing new findings.

## Style

- Comments explain *why* (design rationale, security constraints), not *what*.
  This codebase is deliberately comment-dense about invariants; match that.
- The broad `try/except` blocks in hook paths are the fail-open design rule,
  not slop — keep them.
