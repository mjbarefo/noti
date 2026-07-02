# Changelog

All notable changes to `noti` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] — 2026-07-02

The "someone other than me can install it" release: a public-repo baseline
(license, versioning, CI, screenshots), a universal binary that runs on both Mac
architectures, hardened security around the auto-allow surface, and a `doctor`
that diagnoses a stranger's most likely install problems.

### Added
- `LICENSE` (MIT) and a README license section.
- A single `VERSION` constant driving a top-level `--version` flag, the `version`
  subcommand, and the `doctor` header; `CHANGELOG.md`.
- GitHub Actions CI on an Apple Silicon runner (ruff, universal build, the
  headless policy suite, a best-effort toast-render smoke) with a README badge.
- Rendered toast screenshots (approval / question / plan / summary, light and
  dark) embedded in the README.
- Universal toast binary: `./noti build` compiles arm64 + x86_64 slices pinned to
  a macOS 11 floor and `lipo`s them together, swapping the result into place
  atomically; a toolchain that can't cross-compile falls back to a native build.
- `noti doctor` now checks the macOS/python floor, `~/.claude` presence, the
  binary's architectures vs the host, whether the binary is older than its
  source, and whether the installed hook points at this clone (moved / deleted /
  foreign-clone detection).

### Security
- Closed write/exec holes in the Bash auto-allow safe-list: `git log/diff/show
  --output=FILE` (arbitrary file write) and `--ext-diff` (external diff driver)
  are now refused, and the mutating-capable `git branch` and `tree` were dropped
  from the safe-list.
- Deny-rule matching is now directional-broad: a bare trailing `*` in a Bash rule
  is treated as a prefix for **deny** (so a deny can no longer be under-matched
  and bypassed by the auto-allow), while **allow** matching stays strict.

### Changed
- `evaluate()` is now total against malformed / forward-incompatible hook
  payloads (non-dict `tool_input`, non-string `tool_name`, missing fields):
  every odd shape degrades to a defer or a safe prompt instead of raising.

### Documentation
- Honest install story ("the clone is the install — keep it; `git pull &&
  ./noti build` to upgrade"), macOS 11+ / dual-arch requirements, and documented
  limitations: safe-listed `cat`/`grep` can read any path, and enterprise
  managed-settings deny rules are not read.

## [0.3.0] — 2026-07-01

### Added
- Question & plan surfacing. A simple single-select `AskUserQuestion` becomes a
  toast whose buttons *are* the options (answered via the PreToolUse
  `updatedInput` channel, so the terminal picker never appears); richer sets get
  a non-blocking heads-up. `ExitPlanMode` shows an Approve / View card. Both
  surface in every permission mode, since the session blocks on them regardless.
- Packed stacking: concurrent toasts form one self-healing column. Each toast
  publishes and heartbeats its real pixel height, so cards stack below the true
  column and re-pack smoothly when a neighbour dismisses.

### Changed
- Native-banner restyle: leading tinted icon chip (risk class) with an SF Symbol
  glyph (the tool), ~16pt continuous corners, and Claude's terracotta reserved
  for identity moments — the card reads as a system surface, not a foreign dialog.
- Cards are sized to their content; a clipped command always shows a trailing
  ellipsis so you never approve text you can only partly see.

## [0.2.0] — 2026-06-28

### Added
- Corner-toast approvals: the PreToolUse hook replaces Claude Code's terminal
  permission prompt with a borderless corner toast (Yes / Always / No). Your
  answer becomes the permission decision.
- End-of-turn summary toast (Stop hook): a trimmed final message plus a tool
  tally (`ran N commands · edited M files · …`), auto-dismissing.
- Hover-armed hotkeys: the toast captures the keyboard only after the mouse
  *moves* over it, so a toast surfacing under a parked cursor can never swallow
  an in-flight keystroke.
- Rule minting: "Always" writes an exact `permissions.allow` rule (never a
  broadened glob) that noti's own matcher round-trips; it refuses to clobber an
  unparseable settings file and keeps a `.noti-prev` copy.
- Conservative auto-allow: a read-only Bash safe-list (no shell metacharacters,
  no write/exec/delete flags) and opt-in read-only MCP classification.
- CLI primitives (`noti ask` / `noti notify`) any script or agent can call, plus
  `build` / `install` / `uninstall` / `doctor`.

[Unreleased]: https://github.com/mjbarefo/noti/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/mjbarefo/noti/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/mjbarefo/noti/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mjbarefo/noti/releases/tag/v0.2.0
