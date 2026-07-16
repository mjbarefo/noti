# noti v0.6.1 — the summons stands down

v0.6.0 gave the summons somewhere to stand; v0.6.1 makes it stand *down* the
moment you act. Answering Claude's own terminal prompt fires no hook, so the
pet's `Claude needs you` card could keep standing after you'd already
answered — through an Esc'd turn, a long approved tool, or a session closed
mid-prompt (a zombie summons that impersonates a live one for the whole
30-minute waiting TTL).

## What's fixed

- **`UserPromptSubmit` heals the summons.** The moment you type anything in a
  session, its summons clears — the human just acted, so they are present by
  definition. The handler is silent by contract (this hook's stdout is
  injected as model context) and never emits a decision.
- **`SessionEnd` reaps the session's state.** A closed session cannot need
  you; it can no longer leave a zombie summons standing.
- `noti doctor` flags installs that predate the two new hooks.

Both are housekeeping-only: never a toast, never a permission decision, and
any internal error still defers — degraded, never wrong.

Known remaining case: a long-running tool you approved in the terminal keeps
the summons up until the tool finishes (Claude Code emits no event at
approval time); it clears at the tool's next hook.

## Also in this release

README screenshots caught up with v0.6.0: the standing summons and the
turn-died error toast join the grid, the question card shows its "Other…"
row, and `docs/make-screenshots.sh` regenerates every image from the live
binary so they can't silently fall behind again.

## Install / upgrade

```bash
# fresh install
git clone https://github.com/mjbarefo/noti && cd noti
./noti build
./noti install        # or: ./noti install --project .
./noti doctor

# upgrade an existing clone (the clone IS the install — keep it in place)
git pull && ./noti build
./noti uninstall && ./noti install   # required: registers the new hooks
```

Then start a fresh `claude` session so the hooks reload. Requires macOS 11+ and
the Xcode Command Line Tools for the one-time build; zero third-party
dependencies otherwise.

## Full changelog

See [CHANGELOG.md](../CHANGELOG.md#061--2026-07-16).
