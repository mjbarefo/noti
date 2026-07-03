# noti v0.4.0 — installable by someone who isn't me

*Published as [v0.4.0](https://github.com/mjbarefo/noti/releases/tag/v0.4.0) on 2026-07-02.*

v0.4.0 turns noti from a personal setup into something a stranger can clone,
trust, and install in five minutes on either Mac architecture — with a hardened
permission engine underneath.

## Highlights

- **Universal binary.** `./noti build` now produces an arm64 + x86_64 binary
  pinned to a macOS 11 floor, so it runs natively on both Apple Silicon and
  Intel. The build swaps into place atomically and falls back to a native-only
  build on toolchains that can't cross-compile.
- **A `doctor` that catches real install problems.** It flags an
  architecture-mismatched binary, a binary older than its source, a missing
  `~/.claude`, an unmet macOS/Python floor, and — the big one — a hook that
  points at a clone you've since moved or deleted.
- **CI + screenshots + license + changelog.** GitHub Actions runs the lint,
  universal build, and the full policy suite on an Apple Silicon runner (badge in
  the README). The README now shows the actual cards (approval, question, plan,
  summary) in light and dark. MIT-licensed; changelog back-filled to 0.2.0.

## Security (please upgrade)

Several holes in the auto-allow surface are closed in this release:

- **Shell-splice bypass (arbitrary file write).** The safe-list blocked
  write/exec flags over a naive token split, but quotes and backslashes aren't
  metacharacters — so `git log --out"put"=FILE` cleared the check while bash
  reassembled it into `--output=FILE` and wrote attacker-controlled content to
  any path. The check now tokenizes with `shlex` (shell-accurate), so it sees the
  real argument vector.
- `git log/diff/show --output=FILE` and `--ext-diff` (an external diff driver)
  are no longer auto-allowed, and the mutating-capable `git branch`, `tree`, and
  `date` (macOS clock-set) were removed from the safe-list.
- A `deny` rule with a bare trailing `*` (e.g. `Bash(ls*)`) could be **silently
  bypassed**: noti under-matched the deny, auto-allowed via the safe-list, and a
  PreToolUse allow overrode Claude's own deny enforcement. Deny matching is now
  broadened to match Claude's engine, while allow matching stays strict.

If you already run noti, these fixes take effect the next time you `git pull`.

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

See [CHANGELOG.md](../CHANGELOG.md#040--2026-07-02).
