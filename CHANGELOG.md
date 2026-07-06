# Changelog

All notable changes to `noti` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Toast motion, refined end to end.** Cards now arrive the way system
  banners do — a fade plus a short slide in from the corner's screen edge —
  and *every* exit animates: answering, Esc, timeout, click-to-dismiss, and
  the summary fuse all leave through one `dismissThenExit()` fade (0.15s when
  you acted, 0.3s when a card expires) instead of blinking off mid-glance.
  The answer wire is untouched: stdout is written before the animation, a
  `dismissing` latch makes double-fires impossible, and the keyboard hands
  back to the terminal the instant an answer commits, not when the fade ends.
  Stacked columns stop lurching on the 0.4s poll: each card kqueue-watches
  the slot directory and the column settles ~0.1s after a neighbour's slot
  file disappears (the timer stays as heartbeat and backstop). Everything
  that moves shares one deceleration curve, so concurrent cards read as one
  surface. Reduce-motion keeps the fades and drops the slides.

## [0.5.0] — 2026-07-02

The questions release: `AskUserQuestion` becomes a first-class toast. Options
render as the terminal picker's own numbered list, multi-question calls walk
through one card per question, and a free-text "Other…" row covers the answer
that isn't on the list.

### Added
- **Free-text "Other" on question cards** — the one AskUserQuestion capability
  the terminal still owned for simple questions. Every option-list card now
  ends in a ghost "Other…" row (hairline border, no fill: an escape hatch, not
  a fifth answer). Click it or press the next digit and the row morphs in place
  into a single-line editor — options dim but stay clickable (mouse rescue),
  the keycap becomes ↩, the footer flips to `return · submit  esc · back`, and
  the card's terracotta border says the keyboard lives there. Return submits
  the text **exactly as typed** (dedicated exit code 10 / `RC_OTHER`; stdout
  carries the answer; outer-whitespace strip and paste-only C0-control strip
  are the only canonicalizations; empty submissions are impossible on both
  sides of the wire). Esc backs out one level with the draft preserved as the
  row label; clicking away or Cmd-Tab ends the edit within a frame so the
  armed border never lies about keyboard focus; mouse-leave while typing
  deliberately does *not* disarm (a mid-word disarm would leak the rest of the
  answer into the live terminal). IME-safe by construction: editing keys run
  through the field delegate's command selectors, never raw keycodes, so a
  CJK composition's first Return commits the composition, not the card.
  Kill-switch `approval.question_other: false` hides the row *and* rejects a
  rogue exit-10 (the upstream non-label `updatedInput` contract is
  spike-verified observed behavior, not documented API). Version-skew safe in
  all four quadrants: an old binary ignores the flag (Esc → terminal keeps
  owning Other); an old Python drops exit-10 in its junk bucket (no decision →
  terminal). The row is pure UI — the decision dict, `NOTI_OPTIONS` arity, and
  card eligibility are byte-identical to the option-list cards introduced below.
- **Multi-question calls now toast** (33% of real usage; previously always a
  heads-up notice). A call carrying 2–4 simple questions shows one option-list
  card per question in sequence, with a `2 of 3` progress eyebrow. Answers are
  **all-or-nothing**: partial-`answers` behavior is undocumented upstream, so
  Esc/timeout on any card discards everything collected and the terminal asks
  the full set fresh. The set shares one deadline (`ask_timeout_seconds` total,
  each card's drain showing what's left) — staying inside the installed hook
  timeout, which blocks the tool call outright when exceeded. Calls with
  duplicate question texts (they'd collapse into one `answers` key), empty
  question text, non-dict entries in `questions`, or any non-simple question
  still get the notice — every shape that could smuggle in a partial answer
  is excluded. The turn tally now counts the questions actually answered,
  not the calls.

### Changed
- **Question cards render options as a vertical numbered list** instead of a
  horizontal button row. Labels show in full (2-line wrap with a real ellipsis)
  rather than truncated to 16 characters, each option's *description* renders
  beneath it for the first time, and the hotkeys are now **1–4** — the terminal
  picker's own numbering, immune to the first-letter collisions that left
  similar options without a keycap. A footer advertises the Esc → terminal
  escape hatch. Calibrated against real transcript data (median label 21 chars,
  p95 36; descriptions present on 100% of options).
- Single-select questions with **4 options now toast** (previously only 2–3;
  4-option questions were a quarter of real usage). Multi-question,
  multi-select, and 5+ option sets still get the heads-up notice.
- Return is deliberately inert on question cards: options are peers, and an
  invisible default is how a reflexive keystroke submits an answer the user
  never chose. Return still means Yes/Approve on permission and plan cards.

### Internal
- Full option labels and descriptions ride to the binary in `NOTI_OPTIONS` /
  `NOTI_DESCS` (unit-separator-joined, control chars sanitized so a crafted
  label can never misalign a row against its exit-code index). argv still
  carries the truncated fallback buttons, so a stale binary renders the classic
  card; answers keep round-tripping the exact raw strings by index either way.
  New regression tests cover alignment, env scrubbing, the 4-option answer
  round-trip, and the 5-option boundary.

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
  are now refused, and the mutating-capable `git branch`, `tree`, and `date`
  (macOS clock-set) were dropped from the safe-list.
- The safe-list's dangerous-flag check now tokenizes with `shlex` (shell-accurate
  word splitting), closing a bypass where a blocked flag was spliced across a
  quote or backslash (`git log --out"put"=FILE`) to evade the check while bash
  reassembled it into a real file write.
- Deny-rule matching is now directional-broad: a bare trailing `*` in a Bash rule
  is treated as a prefix for **deny** (so a deny can no longer be under-matched
  and bypassed by the auto-allow), while **allow** matching stays strict.
- Path-anchored allow rules only auto-allow when the payload provides `cwd`, so a
  rule anchored to a guessed directory can't out-vote a deny rule; `cmd_install`
  now takes the same settings-file lock as rule-writing.

### Changed
- `evaluate()` is now total against malformed / forward-incompatible hook
  payloads — a non-dict `tool_input`, a non-string `tool_name`, a non-string
  nested field (`command`, `file_path`, `url`), or missing keys: every odd shape
  degrades to a defer or a safe prompt instead of raising, so `noti decide` and
  any caller stay robust.

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

[Unreleased]: https://github.com/mjbarefo/noti/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/mjbarefo/noti/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/mjbarefo/noti/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/mjbarefo/noti/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mjbarefo/noti/releases/tag/v0.2.0
