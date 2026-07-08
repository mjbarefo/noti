# DEV.md — the roadmap

This file is the forward-looking spec: which Claude Code hook events noti
adopts, skips, or still owes a decision, and the feature backlog behind them.
It exists so that growth is as deliberate as the current code. How to *change*
the code lives in [CONTRIBUTING.md](CONTRIBUTING.md); agent guidance lives in
[CLAUDE.md](CLAUDE.md) — if a sentence would fit in either of those, it does
not belong here. Nothing ships that isn't on this roadmap or trivially in its
spirit.

## The charter test

noti surfaces **only the moments a human is actually needed** and stays silent
otherwise. Every candidate feature is judged by one question: *does this
summon a human who is required, or does it narrate work that is going fine?*
Narration fails the test, always.
One opt-in ambient surface may exist so the summons has somewhere to stand;
everything it shows outside the summons stays inert — no counts, no progress,
no lists.

Explicit non-goals, so they don't creep back in:

- **Session dashboards and multi-agent orchestration** — herdr's job.
- **Session logistics and context plumbing** (compaction, prompt injection,
  worktrees) — ccbaton's lane.
- **Narrating success** — the terminal already shows what Claude did.

## Hook event inventory

Claude Code exposes ~29 hook events (snapshot of
[code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks.md),
**2026-07-06** — re-verify against the live docs before acting on a row).
noti registers two. Consistency does not mean hooking more events; it means
**every event has a verdict**, so a skip is a decision with a reason, not an
omission.

Verdicts: `shipped` · `adopt-P1` · `adopt-P2` · `investigate` · `skip`.

| Event (matcher) | Verdict | Why |
|---|---|---|
| PreToolUse | shipped | The core: approval/question/plan toasts. The only handler that may ever emit a decision (R1). |
| Stop | shipped | End-of-turn summary + tally. Inert by design — never blocks (R2). |
| Notification / `permission_prompt` | **adopt-P1** | The flagship gap: when noti falls back (toast timeout, Esc, ungoverned tool) the terminal dialog shows and today the user gets *zero signal* — the exact moment noti exists for. |
| StopFailure (all reasons) | **adopt-P1** | Turn died on rate-limit/auth/server error; the user waits for a summary toast that never comes. Tiny surface, human-needed moment. |
| PostToolUseFailure | **adopt-P2** | Silent tally-only, so the summary can say "· 1 failed" — the difference between "done" and "done, but look". Never a per-failure toast (spam). |
| Elicitation / ElicitationResult | investigate | An MCP server blocking the session on user input is AskUserQuestion's class, but the contract needs a spike first. |
| Notification / `elicitation_*` | investigate | Folded into the Elicitation spike — same question. |
| Notification / `agent_needs_input`, `agent_completed` | investigate | A background agent blocked on a human is in-charter (v2.1.198+), but spike whether any terminal UI accompanies it before designing copy. |
| SessionStart | investigate | Housekeeping-only candidate (sweep stale tally/slot files at startup). Its stdout becomes model context, so the handler must print nothing (R4). Never a toast. |
| Notification / `idle_prompt` | skip | The Stop summary already announces end-of-turn; a user who set `summary.enabled: false` chose silence — don't reintroduce the nag through a side door. |
| Notification / `auth_success` | skip | Not a human-in-the-loop moment; the terminal shows it. |
| PermissionRequest | skip | Two deciders in one chain is answer-integrity confusion — noti already decided upstream at PreToolUse, and this event doesn't fire headless. Revisit only if `updatedPermissions`/`setMode` becomes the sole way to mint rules Claude honors natively. |
| PermissionDenied | skip | Retry-on-deny is policy, not notification; the deny already surfaced. |
| SubagentStop | skip | Subagent completion is orchestration narration (herdr), and the event is blocking-capable — adopting it would tempt a second decider (R1/R2). |
| SubagentStart | skip | Pure narration. |
| SessionEnd | skip | The user ended the session; telling them so is noise. |
| PostToolUse | skip | Success narration; the tally already counts intent at PreToolUse time. |
| PostToolBatch | skip | Batch narration — same reasoning as PostToolUse. |
| PreCompact / PostCompact | skip | Context logistics — ccbaton's lane. |
| UserPromptSubmit / UserPromptExpansion | skip | The human just acted, so they are present by definition. Context-injecting, too — extra reason to stay away (R4). |
| TeammateIdle | skip | Multi-agent orchestration — herdr's job. |
| TaskCreated / TaskCompleted | skip | Task-list narration is dashboard territory, explicitly out of charter. |
| FileChanged | skip | File watching is not approval; PreToolUse already governs the edits Claude makes. |
| CwdChanged | skip | Session logistics; nothing to decide. |
| WorktreeCreate / WorktreeRemove | skip | Workspace plumbing; nothing human-blocking. |
| ConfigChange | skip | Tempting security signal, but an in-session edit to settings files already routes through an Edit approval toast, and noti re-reads rules per decision — no cache to invalidate. External edits are the user's own. |
| InstructionsLoaded | skip | Context plumbing. |
| MessageDisplay | skip | Would duplicate terminal output — the maximal anti-charter event. |
| Setup | skip | The user is at the keyboard running it. |

## Adopted designs

### Notification / `permission_prompt` — "Claude needs you in the terminal" (P1)

- Register a `Notification` block, matcher `permission_prompt`, command
  `noti hook notification`, no timeout. New branch in `cmd_hook` (noti:1169),
  same fail-open wrapper as the others.
- Non-blocking summary-style toast: title = project basename (the `hook_stop`
  derivation), body "Claude needs you in the terminal — a permission prompt
  is waiting", kind `note` (terracotta is the reserved "Claude wants me"
  signal — this IS that moment).
- **Dedup (R5):** three ways to arrive here. Ungoverned tool → noti never
  toasted, always show. noti toast timed out → the user was away; this is the
  reminder that matters, show. User pressed **Esc** → they deliberately sent
  the prompt to the terminal seconds ago, suppress. Mechanism: `hook_pretooluse`
  drops a best-effort marker file beside the tally (`<sid>.deferred`, reason +
  timestamp); the notification handler suppresses only `esc` within ~10s. A
  missing or unreadable marker degrades to *show* — fail-open here means
  fail-toast, never fail-silent.
- Kill-switch: new `alerts.terminal_prompt` config key (install writes the
  block only when true).
- Open question: does `permission_prompt` also fire for question/plan terminal
  fallbacks? Keep the copy generic so it's correct either way.

### StopFailure — the turn died (P1)

- Register `StopFailure`, no matcher (all reasons), `noti hook stopfailure`,
  no timeout.
- Toast body from a reason→copy map (`rate_limit` → "Turn ended: rate
  limited", likewise `overloaded`, `authentication_failed`, `billing_error`,
  `server_error`, `max_output_tokens`); an unknown reason renders verbatim —
  never guessed at.
- New Swift kind `error`: `.systemRed` chip, `exclamationmark.triangle.fill`
  glyph — two cases in `kindColor`/`kindGlyph` (noti-toast.swift:214/227).
  Red is warranted: this is the one toast whose message is "something broke",
  and borrowing `note`'s terracotta would dilute the identity color.
- **Also read-and-clear the tally** and render it as the footer ("after ran 3
  commands · edited 1 file"). Otherwise the dead turn's tally leaks into the
  next turn's summary or rots until the 48h sweep — the subtle correctness
  win of this hook.
- Kill-switch: `alerts.stop_failure`. Falls out for free: `--kind error` for
  the reusable `noti notify` CLI.

### PostToolUseFailure — failure tally, no toast (P2)

- Register `PostToolUseFailure`, no matcher, `noti hook posttoolusefailure`.
- Handler is a `tally_record_failure()` sibling of `tally_record` (noti:775)
  incrementing a `failed` count; `format_tally` (noti:826) learns "· N
  failed". **No toast ever fires from this handler.**
- Count all tools, not just governed ones — a failed ungoverned tool still
  explains a confusing final message.
- Config: `summary.show_failures` as the rendering knob; the count is always
  recorded (cheap, and the StopFailure footer can use it).

## Under investigation

Each item is gated by one question a spike must answer first (the
`docs/spikes/` pattern: evidence before design).

- **Elicitation / ElicitationResult** — does the session hard-block, and is
  there a documented response channel, or is it dialog-only? Likely v1 is a
  heads-up notify toast ("Server X needs input in the terminal"), the same
  posture as multi-select questions. Toast-*answering* only if the contract
  is documented upstream, and then only behind a kill-switch (R7).
- **Notification / `agent_needs_input` / `agent_completed`** — do background-
  agent prompts show any terminal UI at all? If a blocked background agent is
  truly invisible today, this graduates to P1: it is `permission_prompt`'s
  rationale one step removed. `agent_completed` likely stays skip (narration).
- **SessionStart housekeeping** — adopt only if stale tally/slot files show
  up in practice; the existing 48h sweep (noti:807) may be enough, and a
  third hook on every session start is not free. If adopted: matcher
  `startup`, sweep, exit — stdout stays empty (R4).

## What adopting a hook means

An adoption PR that skips a step is incomplete by definition:

1. **Charter test** — name the human-in-the-loop moment in one sentence. If
   it narrates instead of summons, stop here.
2. **Verdict flip** — update this file's table row, in the same PR.
3. **Handler** — new branch in `cmd_hook` (noti:1169), wrapped in the same
   fail-open try/except: exit 0 and no output on any internal error.
4. **Decision audit** — the handler emits no decision JSON and no stdout
   unless it is `pretooluse` (R1, R4).
5. **Install** — `cmd_install` (noti:1264) writes the block: matcher from
   config where applicable; notify-only handlers get no timeout, deciding
   handlers get `ask_timeout + 30`; merge, never clobber (herdr and ccbaton
   share the settings file).
6. **Uninstall + doctor** — add the event to the uninstall sweep tuple
   (noti:1333) and to doctor's presence/staleness checks (the matcher-currency
   check at noti:1430 is the pattern).
7. **Config** — a kill-switch key in `DEFAULT_CONFIG` (noti:66) with a
   why-comment, plus the README config-table row.
8. **Tests** — test.sh cases: garbage stdin exits 0; the behavior mapping
   (copy / tally / dedup); a regression pinning the dedup rule if any toast
   can co-fire with an existing one.
9. **Surface** — a new toast kind means `kindColor` + `kindGlyph` cases, the
   README kind list, `./noti build`, and preview-toasts snapshots in both
   palettes. CHANGELOG entry last.

## Roadmap invariants

These layer on CONTRIBUTING.md's invariants, which govern the existing code;
these govern growth.

- **R1 — One decider.** Only `hook_pretooluse` may ever emit a decision.
  Every other handler is structurally notify-only — no decision JSON, ever,
  even where the event supports one.
- **R2 — Stop-family events are inert.** noti never blocks from Stop or
  SubagentStop. The `stop_hook_active` anti-loop flag exists because blocking
  Stop hooks can spiral; today's handler is inert and stays that way.
- **R3 — One keyboard-capturing surface.** Only ask-mode toasts arm hotkeys.
  New toasts are non-capturing notify cards unless they go through the full
  hover-armed safety review — keystroke-capture safety is the sacred property.
- **R4 — No stdout on context-injecting events.** Anything printed from
  SessionStart/UserPromptSubmit-class hooks becomes model context; handlers
  on such events write only to the debug log.
- **R5 — At most one toast per human moment.** Any new toast must state which
  existing toast can co-fire and how the duplicate is suppressed (the
  `permission_prompt` marker is the reference implementation).
- **R6 — Every event has a verdict.** A hook event with no row in the
  inventory above is a bug in this document. `doctor` should warn when the
  installed event set drifts from the shipped set (backlog item below).
- **R7 — Observed-behavior features get kill-switches.** Anything built on
  undocumented upstream behavior ships with a config key that fully disables
  it without a code change (precedent: `approval.question_other`).

## Non-hook backlog

| Priority | Item | Notes |
|---|---|---|
| shipped 2026-07-06 | Junk-proof "Always" rules | `make_rule` refuses multiline and >200-char commands — an exact rule for a heredoc can never match a future call, so the "grant" was pure clutter (observed: 150+ multiline entries across real settings files, one 7.7KB). The approval toast hides the Always button whenever minting would refuse, so the button never silently downgrades to a one-time Yes. |
| P1 | Other-editor countdown pause | While the free-text editor is open, pause or extend the deadline drain (≤15s grace). Timing out mid-sentence is the accidental-loss class noti exists to prevent. Swift-side; interacts with the all-or-nothing question-set deadline. |
| P1 | `noti ask --other` CLI flag | Expose the free-text row to the reusable primitive — the exit-10 / RC_OTHER contract already exists. One README line under "Reusable primitives". |
| P2 | Denials in the tally | `tally_record` learns a `denied` count (recorded at decision time in `hook_pretooluse`); summary reads "· denied 1". Pairs with PostToolUseFailure's `failed`. |
| P2 | Doctor: managed-settings warning | Promote the README known-limitation: if `/Library/Application Support/ClaudeCode/managed-settings.json` exists, warn that its deny rules are invisible to noti and suggest emptying `bash_safe_commands`. Read-only check, zero-dep. |
| P2 | Doctor: hook-coverage drift | Compare installed event set against this version's shipped set; "install predates `<event>` — `noti uninstall && noti install`". R6's enforcement arm. |
| P2 | Opt-in per-toast sound | Accessibility: `toast.sound` (default false). NSSound is AppKit — zero-dep holds. Distinct (or no) sound for summary vs ask, so ask stays salient. |
| shipped 2026-07-07 | The pet — a standing summons | Opt-in ambient companion: one non-capturing state-file reader, never a toast suppressor. |
| shipped 2026-07-07 | Prompts grow out of the pet (`pet.attach_prompts`) | The live ask/question/plan toast attaches to a running pet — wears its crab, occludes it, unfurls/retracts — so the prompt reads as the pet, not a corner toast beside it. Still the sole decider (R1) and keyboard surface (R3). |
| P3 | Pet-anchored stacking of concurrent attached prompts | Today a 2nd simultaneous attached prompt overlaps the 1st at the pet (top-answerable first). Stack them downward from the crab using the slot machinery rooted at the anchor, so both are visible — the corner column's behavior, re-based on the pet. |
| P3 | Document `--kind error` | Falls out of StopFailure; README only. |

## The pet — a standing summons (design)

Inspired by [Codex pets](https://developers.openai.com/codex/app/settings):
a small floating companion that reflects agent status — and whose
"waiting for your input" state is noti's entire reason to exist, rendered as
presence instead of an event. A toast is a knock: miss it (away from the desk,
other Space, other monitor) and nothing keeps asking. A pet holding up a
"you're needed" sign **is the standing form of the summons** — it answers
exactly one question at a glance: *does any session need me, and which?*

**The charter tension, stated plainly:** the charter says "narration fails
the test, always" — and a pet's calm *running* pose is presence-as-narration,
full stop. Opt-in doesn't dissolve that; it only changes who is exposed to
it. So shipping the pet requires **amending the charter itself** with one
carve-out sentence: *an opt-in ambient surface may exist so the summons has
somewhere to stand; everything it shows outside the summons stays inert —
no counts, no progress, no lists.* If that sentence can't be written into
the charter with a straight face at implementation time, the pet doesn't
ship. It remains NOT the rejected dashboard: one critter, one question.

Sketch (all of it gated on a `docs/spikes/` spike first):

- **Surface**: a new `pet` mode of the toast binary — same `.accessory` /
  non-activating / all-Spaces NSPanel DNA as the cards, and the *same frosted
  `.popover` surface* (`makeCard`'s material, 16pt continuous corner, hairline
  border) so the pet reads as a member of the toast family, not a separate app
  icon. Small (72pt crab) at rest; draggable, remembers its corner (re-clamped
  on `didChangeScreenParametersNotification` — an undock must not park it
  off-screen). Never the key window (R3), never emits anything (R1). Default
  character: a little terracotta crab — the identity color already means
  "Claude wants me" from across the room.
- **Singular delivery**: the pet *is* the notification surface, not a mascot
  beside one. Two things unfurl out of the crab, and neither is a second
  decider (R5):
  1. **The live prompt (as built, `pet.attach_prompts`).** When the pet is
     running, `hook_pretooluse` (and the question/plan paths) spawn the *ordinary
     ask toast* in **attached** mode instead of at the corner: the toast wears
     the same crab as its leading icon, sits so that crab tile lands exactly on
     the pet's anchor, and — being at least as tall and wide as the 72pt pet tile
     — fully **occludes** the resting pet beneath it. The card grows into the
     screen room the anchor leaves: horizontally away from the nearer edge, and
     vertically up *or* down (the crab rides the card's top edge at a top-corner
     pet, its bottom edge at a bottom-corner pet) so a tall multi-option question
     never centres itself off the screen. A final clamp keeps the whole card in
     the visible frame even on a small display — trading a few px of crab drift
     (a faint pet ghost) for a card that is always fully visible and answerable. The interactive card unfurls
     horizontally out of the crab and retracts back into it on answer, revealing
     the pet again (now in its post-answer mood) with no handoff seam. This keeps
     R1/R3 intact by construction: the attached card is still the same
     hook-spawned decider process and the only keyboard-armed surface — the pet
     process lends only its position (published live in an `.anchor` file the
     toast reads) and its face. No coordination marker is needed: occlusion, not
     a hide/show dance, is what makes it read as one object. The pet skips the
     corner slot column when attached; a *second* concurrent attached prompt
     overlaps at the same spot (top-answerable first) — the documented edge,
     acceptable because the standing pet still counts all waiting sessions and
     simultaneous prompts-with-a-present-human are rare. Kill-switch back to
     corner toasts: `pet.attach_prompts: false` (R7).
  2. **The standing summons (post-timeout).** If the human is away and the
     attached prompt times out, the crab keeps the glanceable `Claude needs you ·
     <project>` (or `· N sessions`) card — the pet's own decorative unfurl, which
     is what the toast was occluding. This is the whole point: a toast is a knock
     you can miss; the pet is its standing form. The card grows into whichever
     side has room so the crab never leaves its corner. Approve/deny still
     happens on a toast or in the terminal — the pet only stands there asking.
- **State feed**: the pet is a long-lived *reader*, never in any hook path.
  Hooks drop per-session, event-stamped state files (`waiting` / `running` /
  `done` / `failed`) into a state dir; the pet kqueue-watches it (the slot
  re-pack pattern) and shows the most-urgent state. **No mtime heartbeat** —
  unlike slot files, nothing lives to re-touch these between hooks, so a
  10-minute build would go falsely stale. Instead: `waiting` expires on its
  natural bound (`ask_timeout + 30`); `running` never expires (a stale
  "running" from a killed session costs a calm pose, not a false summons);
  `done`/`failed` decay to asleep. Known blind spot, documented on purpose:
  no hook fires when a terminal prompt is *answered*, so `waiting` clears
  only at the session's next PreToolUse/Stop — self-healing, but late. Hook
  writes are best-effort: a failed write degrades to a wrong-mood pet, never
  a blocked session.
- **States**: *waiting on you* (the live attached prompt is unfurled out of the
  crab and occluding the pet; once it times out, the pet's own `Claude needs you`
  card stands in its place, project/count named — the whole point) · *running*
  (calm resting crab, no words) · *done* (brief ✓, then rest) · *turn failed*
  (alarmed, presents a card, pairs with StopFailure) · *no sessions* (asleep).
  Only a summons (`waiting`/`failed`) presents the card; every resting state
  stays inert — no counts, no project names — per the charter carve-out. Each state keeps a distinct static crab pose so
  reduce-motion loses only the motion — the unfurl and the idle life (beacon
  breath, blink, gaze, sleep-z, mood reactions) — never the meaning. Focusing the right
  terminal window on click is still a spike question (hook payloads carry only
  `cwd`, ambiguous across tabs and unresolvable over ssh/tmux), not a promise.
- **Personality without a pipeline**: frames are embedded sprite data
  (zero-dep holds); `pet.sprite` may point at a user-supplied sprite-sheet
  PNG — validated on load, silent fallback to the embedded default —
  hatching-by-AI is out of scope, drawing your own is not.
- **Lifecycle**: summoned/dismissed by `noti pet`, detached from its shell
  (the `toast_summary` `start_new_session` pattern); killed by
  `noti uninstall`; no launchd, so no reboot persistence — you re-summon it,
  and that price is documented rather than papered over.
- **Spike questions**: sprite frames vs CALayer vector poses; CPU/battery of
  an always-on surface (animate only on state change?); one pet vs
  per-session pets when several sessions wait at once (until resolved, the
  click card may name more than one); whether any terminal-focus affordance
  is feasible at all; whether the pet ever suppresses a toast (current
  answer: never — different surface class, R5 satisfied by design).

**Rejected**, with reasons, so they don't get re-litigated:

- Session dashboard / multi-session overview — herdr's job. (The pet above
  is not this: one critter, one question, no lists.)
- Linux/Windows port — AppKit *is* the zero-dependency bet.
- Hands-off keyboard answers (no hover-arm) — the arming gesture is the
  keystroke-safety design, not friction to sand off.
- Toast history / log viewer — the terminal scrollback is the record.
- Auto-retry on PermissionDenied — policy, not notification.

## Upstream fragilities to watch

- **`updatedInput` non-label answers** are spike-verified observed behavior,
  not documented API. If a future Claude Code rejects them, flip
  `approval.question_other: false` (the R7 precedent).
- **The hook inventory drifts.** The table above is stamped 2026-07-06;
  re-verify an event against the live docs before implementing its row.
- **`stop_hook_active` semantics** — matters only if R2 is ever revisited;
  document, don't rely.
- **Notification sub-types** — `agent_needs_input`/`agent_completed` are new
  (v2.1.198+) and may still move; the investigate verdicts assume they settle.
