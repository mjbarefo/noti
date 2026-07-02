# Contributing to noti

Thanks for looking at noti. It's a deliberately tiny, zero-dependency tool that
sits in a security-sensitive spot — your Claude Code permission flow — so a few
rules keep it safe to change.

## Dev setup

You need macOS 11+ and the Xcode Command Line Tools (`xcode-select --install`).
That's it — noti is stdlib Python 3 plus one AppKit Swift binary, with no package
manager or third-party dependencies.

```bash
git clone https://github.com/mjbarefo/noti && cd noti
./noti build       # compile the universal toast binary
./test.sh          # run the policy suite (headless — never shows a toast)
make hooks         # once per clone: install the pre-commit gate (lint + tests)
```

`ruff` is the only extra tool, and only for linting. Use Homebrew's (`brew
install ruff`) or any copy on your PATH; `ruff check noti` (the `noti` CLI has no
`.py` extension, so name it explicitly).

## The one rule that matters

**noti's hooks run this working copy in place.** Your global
`~/.claude/settings.json` points at the `noti` script in your clone, so a broken
edit degrades *every* Claude Code session's permission flow (it fails open to the
terminal prompt, but still). Therefore:

- **Never leave `noti` unparseable between edits**, and run `./test.sh` before you
  walk away from a modified `noti`.
- `make hooks` installs a pre-commit gate (`.githooks/pre-commit`) that runs
  `ruff check noti` + `./test.sh`. Keep it enabled.

## Workflow

- `./test.sh` after **any** change to `noti` (policy decisions, rule round-trip,
  security regressions — all headless).
- `./noti build` **and** a snapshot render after any change to
  `bin/noti-toast.swift`
  (`NOTI_SNAPSHOT=/tmp/card.png ./bin/noti-toast ask "Title" "msg" Yes Always No`).
- `ruff check noti` before each commit.
- One logical change per commit.

## Non-negotiable invariants

These are enforced by `test.sh` and by review. Don't work around them.

- **Never block the session.** Every hook entry point exits 0 and emits no
  decision on any internal error. A noti bug must degrade to Claude's own
  permission flow — never a hang, never a spurious allow. The broad `try/except`
  blocks in hook paths are the design, not slop.
- **Deny is checked before everything** — before permission-mode short-circuits,
  allow rules, and the safe-list. Don't reorder `evaluate()`.
- **`make_rule` and `pattern_matches` must round-trip**: any rule noti mints must
  be matched by its own matcher.
- **Stricter-than-Claude is the safe direction for *allow* matching**; deny
  matching is broadened instead, so a deny can never be under-matched and
  bypassed. Keep that asymmetry.
- **Zero dependencies**: stdlib-only Python, AppKit-only Swift. No packages, no
  package managers, no build systems.
- The security regression tests in `test.sh` encode fixed vulnerabilities. Never
  weaken one to make a change pass; add a new one when you fix a new finding.

## Style

Comments explain *why* (design rationale, security constraints), not *what*. This
codebase is deliberately comment-dense about its invariants — match that.
