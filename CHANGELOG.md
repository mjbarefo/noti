# Changelog

All notable changes to `noti` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.1] — 2026-07-16

The patch v0.6.0 taught us to need: a standing summons must stand *down* the
moment you act. Answering in the terminal now clears the pet's card
immediately, and closed sessions can no longer leave zombie summonses.

### Fixed
- **The summons now clears when you answer in the terminal.** Answering
  Claude's own terminal prompt fires no hook, so the pet's `Claude needs you`
  card only healed on the session's *next* PreToolUse/Stop — which never came
  when the answer aborted the turn (Esc at the prompt), the approved tool ran
  long, or the session was closed mid-prompt (leaving a zombie summons that
  could impersonate a live session with the same project name for the whole
  30-minute waiting TTL). `noti install` now registers two silent
  housekeeping hooks: `UserPromptSubmit` marks the session `running` (the
  human just acted — they are present by definition; the handler prints
  nothing, since this hook's stdout becomes model context), and `SessionEnd`
  reaps the ended session's pet state file. Neither ever toasts or emits a
  decision. Existing installs: `noti uninstall && noti install` to register
  the new events; `noti doctor` flags the drift.

### Documentation
- **README screenshots regenerated and completed.** The "What it looks like"
  grid now includes the pet's standing summons and the turn-died error toast
  (both palettes), the question card shows its "Other…" row, and every image
  regenerates from the live binary via `docs/make-screenshots.sh` — the
  renders were previously hand-run and had silently fallen a release behind.

## [0.6.0] — 2026-07-16

The pet release: the summons gets somewhere to stand. An opt-in floating
robot reflects each session's state, presents the live approval/question/plan
card out of its own body, holds a standing `Claude needs you` card that says
how long it has stood — and clicking it lands you in the terminal that asked.
A dead turn (rate limit, auth, server error) finally says so instead of going
silent.

### Added
- **A dead turn now says so (StopFailure).** When a turn dies on a rate
  limit, auth failure, or server error, the summary toast the user is waiting
  for never comes — previously that moment was pure silence. `noti install`
  now registers the `StopFailure` hook: a red `error` toast (new kind, also
  available to `noti notify --kind error`) names the reason from a documented
  copy map (unknown reasons render verbatim, control-stripped), carries the
  dead turn's tally as its footer ("after ran 3 commands · edited 1 file") —
  read-and-cleared so it can't leak into the next turn's summary — and stands
  the pet's alarmed `failed` summons, which now persists like `waiting`
  instead of decaying in 6 seconds. Kill-switch: `alerts.stop_failure`.
  Existing installs: `noti uninstall && noti install` to register the event.
- **Opt-in pet companion.** `noti pet` starts a small non-activating floating
  robot that watches best-effort per-session state files. It shares the toasts'
  frosted surface and *is* the delivery: on a summons it unfurls one card out of
  the robot (`Claude needs you · project`), and collapses back to just the robot
  when running, done, or asleep — never becoming a second decider. Hook writes
  are gated by `pet.enabled: false` by default; failures are debug-only and never
  affect permission decisions. `noti uninstall` also stops a running pet.
- **Prompts delivered through the pet.** When the pet is running, the interactive
  approval/question/plan toast now grows *out of the robot* at the pet's spot —
  the same robot becomes the card's leading icon and the card unfurls from it,
  then retracts back into it when you answer — instead of a separate corner toast
  beside a decorative pet card. It is still the one decider and the one
  keyboard-armed surface (the pet only lends its position and its face); the pet
  republishes its live position in an `.anchor` file so the card lands exactly on
  it. New `pet.attach_prompts` (default `true`) is the kill-switch back to
  corner toasts. Off (pet disabled), nothing changes.

- **The pet is alive.** The robot blinks every few seconds (randomly — a
  metronome blink reads as a cursor), glances toward whatever card it is
  presenting, lands a `done` with a happy squash-and-rebound bounce, startles
  with a shake on `failed`, and floats a slow fading "z" while asleep. All of
  it is reduce-motion-gated, and none of it costs the CPU anything: blinks are
  one-shot timers (two redraws each), and every repeating motion — including
  the beacon's breathing halo, previously a 30fps timer redraw burning ~5% CPU
  all session — now runs on the render server while the process sleeps
  (measured: 0.1% CPU awake, 0.0% asleep). The robot fronting an attached
  prompt card breathes and blinks the same way, so the retract handoff reveals
  a pet mid-breath instead of a jump from a frozen glow.
- **Click the summons, land in the right terminal.** Clicking the pet's
  standing `Claude needs you` card now focuses the terminal that owns the
  waiting session. Hooks stamp the session's TTY and terminal app into the
  summons state file (a ppid walk from the hook process — the shell ancestors
  carry the TTY that `cwd` alone could never disambiguate); the pet then
  selects the Terminal.app tab whose `tty` matches via AppleScript, falls
  back to activating the owning app (iTerm2, VS Code, ssh chains), and by
  design does nothing when identity wasn't captured — it never focuses a
  guessed window. Spike-verified before wiring (`docs/spikes/spike-focus.sh`);
  first click may show a one-time macOS Automation consent. Kill-switch:
  `pet.focus_terminal`.
- **The summons actually stands — and says how long.** The pet's
  `Claude needs you` card now shows how long the summons has stood
  (`noti · 4m`; the oldest wait when several sessions stand), and a new
  `pet.waiting_ttl_seconds` (default 30 minutes, never less than
  `ask_timeout+30`) replaces the old toast-lifetime bound that retracted the
  standing summons 30 seconds after the toast timed out — while the prompt it
  announced was still waiting in the terminal. A prompt answered in the
  terminal still self-heals within seconds via that session's next hook; only
  a session killed mid-prompt can leave a false summons, and it dies at the
  TTL.
- **Pet mood-matrix snapshots.** `NOTI_PET_SNAPSHOT_DIR` writes a PNG of the
  whole pet surface after each state change settles, and
  `NOTI_PET_REDUCE_MOTION` forces the static branch for deterministic
  captures — one pet process can walk every mood and emit a labeled pose
  matrix for design review (procedure in the preview-toasts skill).

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
- **The robot, machined.** An art pass over the pet's draw path, same
  silhouette and mood palette: arms and legs are outlined capsules instead of
  bare strokes, the head and torso carry a shallow top-lit gradient, ear nubs
  widen the silhouette, the eyes gained pinprick catchlights, and the mouth
  now agrees with the chest glyph — a smile on `done`, a startled "o" on
  `failed`. The attached prompt card inherits all of it through the shared
  renderer.

### Fixed
- **Summons text stays on the card for a left-half pet.** The unfurled
  `Claude needs you` labels used a flexible-left-margin autoresizing mask on
  one side, so a pet resting on the left half of the screen unfurled a card
  whose text slid off-panel by the width delta. Both labels now hold their
  left position invariant through the resize. Same class of bug fixed in the
  reduce-motion jump-cut path, where the robot tile itself landed off-panel
  (pre-positioned subviews double-shifted by autoresizing).
- **"Always" no longer mints junk rules.** Approving a heredoc/multiline or
  >200-character command with Always used to write the entire script into
  `permissions.allow` as an exact "rule" — one that could never match a future
  call (nobody re-runs a 2KB script byte-identically), leaving settings files
  bloated and unauditable. `make_rule` now refuses such commands (the same
  posture as the trailing-`*` refusal), and the approval toast simply doesn't
  offer the Always button when minting would refuse — a button that silently
  does less than it says is a lie the UI no longer tells.

### Documentation
- **DEV.md, the roadmap.** Every Claude Code hook event (29 as of the
  2026-07-06 docs snapshot) now carries an explicit adopt/skip verdict with
  its reason, so hook coverage is a set of decisions instead of a set of
  gaps. Plus: the "what adopting a hook means" checklist, seven growth
  invariants (one decider; Stop-family stays inert; one keyboard-capturing
  surface; …), the prioritized non-hook backlog, and the rejected list.
  README and CONTRIBUTING point to it.

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

[0.6.1]: https://github.com/mjbarefo/noti/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/mjbarefo/noti/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/mjbarefo/noti/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/mjbarefo/noti/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/mjbarefo/noti/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mjbarefo/noti/releases/tag/v0.2.0
