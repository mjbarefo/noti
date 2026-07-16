# noti v0.6.0 — the pet: a standing summons

A toast is a knock: miss it — away from the desk, other Space, other monitor —
and nothing keeps asking. v0.6.0 gives the summons somewhere to stand. An
opt-in floating robot reflects each session's state, and when Claude needs
you it holds up a card that stays until you answer, says how long it has
stood, and — clicked — lands you in the terminal that asked.

## Highlights

- **`noti pet`** starts a small floating robot on the toasts' own frosted
  surface. It never takes your keyboard, never emits a decision, and never
  becomes a second dashboard: one critter, one question — *does any session
  need me, and which?* Blinks, breathes, bounces on `done`, startles on
  `failed`; all of it reduce-motion-gated and all repeating motion on the
  render server (measured: ~0.1% CPU awake, 0.0% asleep). Off by default
  (`pet.enabled`).
- **Prompts grow out of the pet.** With the pet running, the live
  approval/question/plan toast unfurls *out of the robot* — the same robot
  becomes the card's leading icon, and the card retracts back into it when
  you answer. Still the one decider and the one keyboard-armed surface; the
  pet only lends its position and its face. Kill-switch: `pet.attach_prompts`.
- **The summons actually stands.** `Claude needs you · project` persists until
  answered (default TTL 30 minutes, `pet.waiting_ttl_seconds`) and shows how
  long it has stood (`noti · 4m`). A prompt answered in the terminal
  self-heals within seconds.
- **Click-to-focus.** Clicking the standing summons focuses the terminal that
  owns the waiting session: hooks stamp the session's TTY via a ppid walk at
  summons time, the pet selects the matching Terminal.app tab by `tty`, falls
  back to activating the owning app (iTerm2, VS Code, ssh chains), and does
  nothing when identity wasn't captured — it never focuses a guessed window.
  First click may show a one-time macOS Automation consent. Kill-switch:
  `pet.focus_terminal`.
- **A dead turn now says so.** When a turn dies on a rate limit, auth failure,
  or server error, the summary you're waiting for never comes — that moment
  used to be pure silence. The new `StopFailure` hook shows a red `error`
  toast naming the reason, carrying the dead turn's tally as its footer, and
  stands the pet's alarmed summons. Kill-switch: `alerts.stop_failure`.
- **Toast motion, refined.** Cards slide in from the corner's screen edge,
  every exit animates through one fade, and stacked columns re-pack the
  moment a neighbour dismisses (kqueue, not the 0.4s poll). One deceleration
  curve everywhere; reduce-motion keeps the fades and drops the slides.
- **"Always" no longer mints junk rules.** Approving a multiline or
  >200-character command with Always used to write the whole script into
  `permissions.allow` as an unmatchable "rule". Minting now refuses, and the
  toast hides the Always button whenever it would — a button that silently
  does less than it says is a lie the UI no longer tells.

## Safety posture (unchanged)

The pet is presence, not power: hook writes to its state files are
best-effort, failures are debug-only, and no pet path can touch a permission
decision. Deny rules still win before every allow path, everything the toast
can't represent faithfully still falls back to the terminal untouched, and
any internal error still defers to Claude's own flow — degraded, never wrong.

## Install / upgrade

```bash
# fresh install
git clone https://github.com/mjbarefo/noti && cd noti
./noti build
./noti install        # or: ./noti install --project .
./noti doctor

# upgrade an existing clone (the clone IS the install — keep it in place)
git pull && ./noti build
./noti uninstall && ./noti install   # one-time: registers the new StopFailure hook

# meet the pet (opt-in): set pet.enabled: true in noti.config.json, then
./noti pet
```

Then start a fresh `claude` session so the hooks reload. Requires macOS 11+ and
the Xcode Command Line Tools for the one-time build; zero third-party
dependencies otherwise.

## Full changelog

See [CHANGELOG.md](../CHANGELOG.md#060--2026-07-16).
