# noti v0.5.0 — questions become first-class

*Published as [v0.5.0](https://github.com/mjbarefo/noti/releases/tag/v0.5.0) on 2026-07-02.*

v0.5.0 is about the other half of the human-in-the-loop conversation. Approvals
were already toasts; now `AskUserQuestion` is too — rendered the way the
terminal renders it, answered with one keypress, and with a free-text escape
hatch for the answer that isn't on the list.

## Highlights

- **Options as a numbered list.** Question cards render options vertically —
  full labels (2-line wrap, real ellipsis), each option's *description* shown
  for the first time — and the hotkeys are **1–4**, the terminal picker's own
  numbering, immune to first-letter collisions. Calibrated against real
  transcript data (median label 21 chars, p95 36). 4-option questions now
  toast too (a quarter of real usage).
- **Multi-question calls toast** (a third of real usage; previously a
  heads-up notice). A call carrying 2–4 simple questions shows one card per
  question with a `2 of 3` progress eyebrow, all sharing one deadline. Answers
  are **all-or-nothing**: partial-answer behavior is undocumented upstream, so
  Esc or timeout on any card discards everything and the terminal asks the
  full set fresh — noti never submits a half-answered call.
- **A free-text "Other…" row** ends every option list. Click it (or press the
  next digit) and the row morphs into an inline single-line editor: Return
  submits your text **exactly as typed**, Esc backs out with the draft kept.
  While you type, the keyboard stays pinned to the card — the terracotta
  border never lies about who has your keystrokes — and the field is IME-safe
  (a CJK composition's first Return commits the composition, not the card).
  The answer rides a dedicated exit code, so a crashing binary's diagnostics
  can never become your answer; kill-switch: `approval.question_other: false`.

## Safety posture (unchanged)

Everything the toast can't represent faithfully — multi-select, 5+ options,
duplicate question texts — still falls back to the terminal untouched. Deny
rules still win before every allow path, answers round-trip the exact raw
option strings by index, and a too-old Claude Code simply ignores the answer
channel and asks in the terminal: degraded, never wrong.

## Install / upgrade

```bash
# fresh install
git clone https://github.com/mjbarefo/noti && cd noti
./noti build
./noti install        # or: ./noti install --project .
./noti doctor

# upgrade an existing clone (the clone IS the install — keep it in place)
git pull && ./noti build
```

Then start a fresh `claude` session so the hooks reload. Requires macOS 11+ and
the Xcode Command Line Tools for the one-time build; zero third-party
dependencies otherwise.

## Full changelog

See [CHANGELOG.md](../CHANGELOG.md#050--2026-07-02).
