# Changelog

All notable changes to `noti` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/mjbarefo/noti/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/mjbarefo/noti/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mjbarefo/noti/releases/tag/v0.2.0
