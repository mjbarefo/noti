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
| P3 | Document `--kind error` | Falls out of StopFailure; README only. |

**Rejected**, with reasons, so they don't get re-litigated:

- Session dashboard / multi-session overview — herdr's job.
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
