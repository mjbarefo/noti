# C6: live matcher verification gate

Status, 2026-10-30: **pending**. No Claude Code CLI or live permission matcher is
available in the implementation environment. Local `noti decide` results are
not upstream evidence. This patch changes no redirect parsing, rule matching,
or rule minting behavior for C6.

## What is already established

- On PR #2, a `Bash(ls -la:*)` allow still covers
  `ls -la > ~/.zshrc` in Manual/default mode. The corresponding `git log` append
  example is also unresolved. These are matcher dry runs, not executed commands.
- With no matching allow rule, `_BASH_META` rejects `<` and `>` before the
  read-only safe-list can approve a command. `test.sh` now pins output, append,
  descriptor, input, read/write, and `/dev/null` cases through `evaluate()`.
- C1 defers routine auto-mode calls without consulting allow rules. C4 can
  surface an explicit ask. Neither supplies target-file enforcement in Manual
  mode for a call that matches a user-authored Bash allow rule.
- Tests also pin quoted/escaped literal `>` under explicit rules and a compound
  deny after a redirect. The existing asymmetric C2/C3 matcher stays intact.

## Documentation evidence, not live verification

The upstream [permissions reference, Redirections](https://code.claude.com/docs/en/permissions#redirections),
checked 2026-10-30, describes output targets checked against Edit rules and input
targets against Read rules, alongside working-directory/path restrictions. It
also documents exceptions for targets without files, including `/dev/null`,
descriptor duplication, and here-documents/strings. A Bash allow for the command
does not, by itself, grant access to its target.

That is more specific than treating redirects as extra command separators.
It does not establish the installed engine's behavior, or whether a noti
PreToolUse `allow` can skip a target check. Both need an observed result before
selecting a patch. Also consult upstream [hook precedence](https://code.claude.com/docs/en/permissions#precedence-among-rules-hooks-and-mods).

## Controlled live probe

1. Record `claude --version`, platform, permission mode, sandbox configuration,
   working directories, and every effective rule source. Use a fresh disposable
   project and an isolated test settings profile. No ambient Bash/Edit/Read allow
   should accidentally cover a fixture; keep managed settings visible in the record.
2. Create a project directory and a sibling outside directory under one temporary
   root. Use only fixture files, with known initial contents for append/input
   cases. Initialize a small git repository for the `git log` control. `PROJECT`
   and `OUTSIDE` below mean the literal absolute paths of these directories, not
   shell variables in submitted commands. Quote substituted paths as needed.
3. Baseline: disable noti's PreToolUse hook **in that test profile**. Use Manual
   mode (`default`), a fresh session per rule change, and exactly the indicated
   Bash allow rule. Request one exact command at a time. Record the actual Bash
   `tool_input`, native permission outcome/reason, and target contents before/after.
   A command Claude rewrites is not a result for the requested probe.
4. Repeat with noti enabled from the patched PR branch. Record `noti decide`
   alongside the actual hook JSON and native outcome. This separates noti's
   classifier result from Claude's target check. Check auto mode separately;
   a routine noti defer is not proof that Manual-mode target checks are safe.
5. Repeat file-target cases with no file rule, a matching Edit/Read allow, a
   matching deny, and an ask where supported. Include an isolated test-home
   tilde target and quoted paths. Never use real shell startup or SSH files.

| Exact command shape | Bash allow rule | Distinction to record |
|---|---|---|
| `ls -la` | `Bash(ls -la:*)` | Plain-command control |
| `ls -la > PROJECT/out.txt` | `Bash(ls -la:*)` | Working-directory file write |
| `ls -la > OUTSIDE/out.txt` | `Bash(ls -la:*)` | Outside file write |
| `ls -la >> OUTSIDE/out.txt` | `Bash(ls -la:*)` | Append versus overwrite |
| `git log --oneline >> OUTSIDE/out.txt` | `Bash(git log:*)` | Second original C6 verb |
| `ls -la 2> OUTSIDE/stderr.txt` | `Bash(ls -la:*)` | Numeric descriptor prefix |
| `cat < OUTSIDE/input.txt` | `Bash(cat:*)` | Input read rule |
| `cat <> OUTSIDE/input.txt` | `Bash(cat:*)` | Read/write redirect |
| `ls -la > /dev/null` | `Bash(ls -la:*)` | Documented no-file exception |
| `ls -la 2>&1` | `Bash(ls -la:*)` | Descriptor duplication |
| `echo "a > b"` | `Bash(echo:*)` | Quoted literal control |
| `echo a \> b` | `Bash(echo:*)` | Escaped literal control |

No live rows have been measured. For each row, attach version/settings, exact
input, native result without noti, noti verdict/hook JSON, native result with
noti, and file observations. Docs-based predictions do not fill these columns.

## Smallest follow-up after the gate

- If native target checks survive noti's hook approval, document the verified
  boundary and add fixtures that reproduce it before deciding whether a stricter
  local guard is warranted. Do not invent a target bypass from `noti decide` alone.
- If noti's approval skips a required native check, prefer a quote-aware,
  fail-closed refusal of local allow matching for the verified redirect shapes
  over a new shell parser. Measure extra prompts for permitted targets before
  deciding between this deliberately stricter policy and target-aware matching.
- Keep `_bash_deny_parts` and deny-first evaluation unchanged. Candidate code
  paths are `noti:_bash_allow_parts`, `matches_any`, and `make_rule`; any shape
  refused by allow matching must also be refused by minting so round-trip holds.
- Add direct and `evaluate()` regressions in `test.sh`: original overwrite and
  append reproductions, descriptor/input/read-write cases selected by the probe,
  quoted/escaped controls, deny precedence, and mint/match round-trip. Update
  `README.md` and the C6 status in `DEV.md` with the chosen compatibility cost.
  Run `ruff check noti` and `./test.sh`. Do not make today's unresolved allow
  outcome a passing security regression, and do not call C6 fixed before this work.
