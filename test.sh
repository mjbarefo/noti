#!/usr/bin/env bash
# Policy smoke tests — exercise `noti decide` (never shows a toast).
set -uo pipefail
cd "$(dirname "$0")"

# Hermetic environment. `noti decide` resolves allow/deny rules from HOME's and
# the payload cwd's .claude/settings — so without isolation the suite reads the
# developer's ambient rules (a github.com allow rule in a gitignored
# .claude/settings.local.json is why the "allowed domain" test passed locally but
# failed on a clean CI runner). Point HOME and CWD at a fixture that supplies
# exactly the rule the tests assert, so results are identical everywhere.
FIX="$(mktemp -d)"
export HOME="$FIX"
export XDG_CONFIG_HOME="$FIX/.config"
mkdir -p "$FIX/.claude"
printf '%s\n' '{"permissions":{"allow":["WebFetch(domain:github.com)"]}}' > "$FIX/.claude/settings.json"
trap 'rm -rf "$FIX"' EXIT

pass=0; fail=0
check() {  # check "name" "<json>" "<expected action>"
  local got
  got=$(printf '%s' "$2" | ./noti decide | python3 -c 'import sys,json;print(json.load(sys.stdin)["action"])')
  if [ "$got" = "$3" ]; then
    echo "  ok   $1 -> $got"; pass=$((pass+1))
  else
    echo "  FAIL $1 -> got '$got', want '$3'"; fail=$((fail+1))
  fi
}

CWD="$FIX"
j() { printf '{"tool_name":"%s","tool_input":%s,"permission_mode":"%s","cwd":"%s","session_id":"test"}' "$1" "$2" "$3" "$CWD"; }

echo "noti policy tests"
check "safe bash (git status)"      "$(j Bash '{"command":"git status"}' default)"            allow
check "safe bash w/ metachars"      "$(j Bash '{"command":"ls; rm -rf x"}' default)"          prompt
check "risky bash (rm -rf)"         "$(j Bash '{"command":"rm -rf build"}' default)"          prompt
check "edit file"                   "$(j Edit '{"file_path":"/tmp/x.txt"}' default)"          prompt
check "webfetch (new domain)"       "$(j WebFetch '{"url":"https://example.com/x"}' default)" prompt
check "webfetch (allowed domain)"   "$(j WebFetch '{"url":"https://github.com/x"}' default)"  allow
check "bypass mode defers"          "$(j Bash '{"command":"rm -rf build"}' bypassPermissions)" defer
check "plan mode defers"            "$(j Edit '{"file_path":"/tmp/x"}' plan)"                  defer
check "acceptEdits allows edit"     "$(j Edit '{"file_path":"/tmp/x"}' acceptEdits)"          allow
check "acceptEdits still toasts bash" "$(j Bash '{"command":"rm -rf x"}' acceptEdits)"        prompt
check "read-only tool defers"       "$(j Read '{"file_path":"/tmp/x"}' default)"              defer
check "read mcp prompts (opt-in off)" "$(j mcp__claude_ai_Gmail__search_threads '{}' default)" prompt
check "mutating mcp prompts"        "$(j mcp__claude_ai_Gmail__create_draft '{}' default)"    prompt
check "env bash NOT auto-allowed"   "$(j Bash '{"command":"env rm -rf /tmp/x"}' default)"     prompt
check "find -delete NOT allowed"    "$(j Bash '{"command":"find . -delete"}' default)"        prompt
check "git --output NOT auto-allowed" "$(j Bash '{"command":"git log --output=/tmp/x"}' default)" prompt
check "git branch NAME NOT auto-allowed" "$(j Bash '{"command":"git branch evil"}' default)"  prompt
check "dontAsk mode defers"         "$(j Bash '{"command":"rm -rf build"}' dontAsk)"          defer
check "auto mode still governs"     "$(j Bash '{"command":"rm -rf build"}' auto)"             prompt

# v0.3: Claude-to-human interaction tools surface in every permission mode
check "simple question toasts"      "$(j AskUserQuestion '{"questions":[{"question":"Which auth approach?","header":"Auth","options":[{"label":"JWT"},{"label":"Sessions"},{"label":"OAuth"}],"multiSelect":false}]}' default)" question
check "question surfaces in bypass" "$(j AskUserQuestion '{"questions":[{"question":"Proceed?","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}' bypassPermissions)" question
check "multiSelect question notifies" "$(j AskUserQuestion '{"questions":[{"question":"Pick features","options":[{"label":"A"},{"label":"B"}],"multiSelect":true}]}' default)" notice
check "multi-question toasts (all simple)" "$(j AskUserQuestion '{"questions":[{"question":"Q1","options":[{"label":"A"},{"label":"B"}]},{"question":"Q2","options":[{"label":"C"},{"label":"D"}]}]}' default)" question
check "multi-question w/ multiSelect notifies" "$(j AskUserQuestion '{"questions":[{"question":"Q1","options":[{"label":"A"},{"label":"B"}]},{"question":"Q2","options":[{"label":"C"},{"label":"D"}],"multiSelect":true}]}' default)" notice
check "multi-question w/ 5-option notifies" "$(j AskUserQuestion '{"questions":[{"question":"Q1","options":[{"label":"A"},{"label":"B"}]},{"question":"Q2","options":[{"label":"C"},{"label":"D"},{"label":"E"},{"label":"F"},{"label":"G"}]}]}' default)" notice
check "5 questions notify"          "$(j AskUserQuestion '{"questions":[{"question":"Q1","options":[{"label":"A"},{"label":"B"}]},{"question":"Q2","options":[{"label":"A"},{"label":"B"}]},{"question":"Q3","options":[{"label":"A"},{"label":"B"}]},{"question":"Q4","options":[{"label":"A"},{"label":"B"}]},{"question":"Q5","options":[{"label":"A"},{"label":"B"}]}]}' default)" notice
check "non-dict question entry notifies" "$(j AskUserQuestion '{"questions":[{"question":"Q1","options":[{"label":"A"},{"label":"B"}]},"stray-junk"]}' default)" notice
check "empty question text notifies" "$(j AskUserQuestion '{"questions":[{"header":"Pick","options":[{"label":"A"},{"label":"B"}]}]}' default)" notice
check "4-option question toasts"    "$(j AskUserQuestion '{"questions":[{"question":"Q","options":[{"label":"A"},{"label":"B"},{"label":"C"},{"label":"D"}]}]}' default)" question
check "5-option question notifies"  "$(j AskUserQuestion '{"questions":[{"question":"Q","options":[{"label":"A"},{"label":"B"},{"label":"C"},{"label":"D"},{"label":"E"}]}]}' default)" notice
check "plan review toasts (plan mode)" "$(j ExitPlanMode '{"plan":"# Plan\n1. do the thing"}' plan)" plan

echo
echo "rule round-trip (an 'Always' rule must match the next identical call)"
python3 - "$CWD" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("notimod", "./noti").load_module()
cfg = m.load_config()
cases = [
    ("Bash", {"command": "npm run build"}),
    ("Edit", {"file_path": sys.argv[1] + "/x.txt"}),
    ("MultiEdit", {"file_path": sys.argv[1] + "/y.txt"}),
    ("WebFetch", {"url": "https://api.example.org/x"}),
    ("mcp__claude_ai_Gmail__create_draft", {}),
]
bad = 0
for tool, ti in cases:
    rule = m.make_rule(tool, ti, cfg)
    ok = bool(rule) and m.pattern_matches(tool, ti, rule)
    print(f"  {'ok  ' if ok else 'FAIL'} {tool}: rule={rule} matches={ok}")
    bad += 0 if ok else 1
sys.exit(1 if bad else 0)
PY
rt=$?

echo
echo "security regressions (fixed review findings must stay fixed)"
python3 - "$CWD" <<'PY'
import sys, copy
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("notimod", "./noti").load_module()
cfg = m.load_config()
bad = 0
def want(name, cond):
    global bad
    print(f"  {'ok  ' if cond else 'FAIL'} {name}")
    bad += 0 if cond else 1

# F1/F7: env/find/rg are not auto-allowed; genuinely-safe verbs still are
want("env exec not safe",        not m.is_safe_bash("env bash evil.sh", cfg))
want("find -delete not safe",    not m.is_safe_bash("find . -delete", cfg))
want("rg --pre not safe",        not m.is_safe_bash("rg --pre x foo .", cfg))
want("git status still safe",        m.is_safe_bash("git status", cfg))
want("grep -o still safe",           m.is_safe_bash("grep -o foo bar", cfg))

# v0.4 F9: git write/exec flags on a safe verb are NOT auto-allowed (file clobber / exec)
want("git log --output= not safe",   not m.is_safe_bash("git log --output=/tmp/x", cfg))
want("git diff --output not safe",   not m.is_safe_bash("git diff --output /tmp/x", cfg))
want("git show --output= not safe",  not m.is_safe_bash("git show --output=/tmp/x HEAD", cfg))
want("git diff --ext-diff not safe", not m.is_safe_bash("git diff --ext-diff", cfg))
# ...but the long-form --output block must NOT over-reach to grep's read-only -o
want("grep -o not over-blocked",         m.is_safe_bash("grep -o foo bar", cfg))
# v0.4 F10: mutating `git branch NAME/-D` and niche `tree -o` dropped from the safe-list
want("git branch NAME not safe",     not m.is_safe_bash("git branch evil", cfg))
want("git branch -D not safe",       not m.is_safe_bash("git branch -D main", cfg))
want("tree -o not safe",             not m.is_safe_bash("tree -o /tmp/x", cfg))
want("date dropped (macOS clock set)", not m.is_safe_bash("date 010112002020", cfg))

# v0.4 F12 (CRITICAL): the dangerous-flag check tokenizes like the SHELL, so a
# blocked flag can't be spliced across a quote or backslash. cmd.split() saw one
# opaque token that missed `--output`; bash reassembles it into a real file write.
want("quote-spliced --output not safe",     not m.is_safe_bash('git log --out"put"=/tmp/x', cfg))
want("backslash-spliced --output not safe", not m.is_safe_bash("git log --out\\put=/tmp/x", cfg))
want("quote-spliced --ext-diff not safe",   not m.is_safe_bash('git diff --ext-di""ff', cfg))
want("splice + attacker content not safe",  not m.is_safe_bash('git log --pretty=format:"x" --out\\put=/tmp/x', cfg))
# ...and shell-accurate tokenization must NOT falsely block legitimate quoting
want("quoted grep arg still safe",              m.is_safe_bash('grep --include="*.py" foo bar', cfg))
want("unbalanced quotes fail closed",       not m.is_safe_bash('grep "unterminated', cfg))

# F2: an exact Bash 'Always' rule must NOT glob-broaden
want("exact rule matches itself",      m.pattern_matches("Bash", {"command":"rm -rf node_modules/*"}, "Bash(rm -rf node_modules/*)"))
want("exact rule does NOT broaden", not m.pattern_matches("Bash", {"command":"rm -rf node_modules/../.ssh"}, "Bash(rm -rf node_modules/*)"))

# v0.4 F11: DENY matching is directional-broad — a bare trailing * in a Bash
# deny rule is a prefix (mirrors Claude), so noti can't under-match and let a
# deny be bypassed. ALLOW matching stays strict (bare * literal) to preserve
# the round-trip and stricter-than-Claude-for-allow.
want("deny Bash(ls*) matches 'ls -la'",   m.pattern_matches("Bash", {"command":"ls -la"}, "Bash(ls*)", broad=True))
want("deny Bash(ls*) matches 'lsof'",      m.pattern_matches("Bash", {"command":"lsof"}, "Bash(ls*)", broad=True))
want("allow Bash(ls*) stays literal", not m.pattern_matches("Bash", {"command":"ls -la"}, "Bash(ls*)"))
want("deny Bash(rm*) matches rm -rf /",    m.pattern_matches("Bash", {"command":"rm -rf /"}, "Bash(rm*)", broad=True))
# end-to-end: a deny rule with a bare * must NOT be bypassed by the safe-list
_save_lp = m.load_patterns
m.load_patterns = lambda cwd, kind: (["Bash(ls*)"] if kind == "deny" else [])
try:
    dbz = m.evaluate({"tool_name":"Bash","tool_input":{"command":"ls -la"},
                      "permission_mode":"default","cwd":sys.argv[1]}, cfg)
    want("safe-list can't bypass a broad deny", dbz["action"] == "deny")
finally:
    m.load_patterns = _save_lp

# F3: MCP auto-allow is opt-in and mutating-token aware
want("mcp off by default",       not m.is_read_only_mcp("mcp__db__query", cfg))
optin = copy.deepcopy(cfg); optin["approval"]["mcp_autoallow_servers"] = ["claude_ai_Gmail"]
want("opt-in read mcp allows",       m.is_read_only_mcp("mcp__claude_ai_Gmail__search_threads", optin))
want("opt-in mutating mcp blocked",  not m.is_read_only_mcp("mcp__claude_ai_Gmail__search_and_replace", optin))
want("opt-in query verb blocked",    not m.is_read_only_mcp("mcp__claude_ai_Gmail__query", optin))

# F6: server-scoped MCP pattern matches its tools (deny path)
want("mcp__db deny scopes tools",    m.pattern_matches("mcp__db__query", {}, "mcp__db"))

# F4/F8: deny is checked before the acceptEdits short-circuit
orig = m.load_patterns
m.load_patterns = lambda cwd, kind: (["Edit(//private/etc/**)"] if kind == "deny" else [])
try:
    d = m.evaluate({"tool_name":"Write","tool_input":{"file_path":"/private/etc/hosts"},
                    "permission_mode":"acceptEdits","cwd":sys.argv[1]}, cfg)
    want("deny beats acceptEdits", d["action"] == "deny")
finally:
    m.load_patterns = orig

# F5: write_rule refuses to clobber an unparseable settings file
import tempfile, os, json
d = tempfile.mkdtemp(); cl = os.path.join(d, ".claude"); os.makedirs(cl)
corrupt = os.path.join(cl, "settings.local.json")
open(corrupt, "w").write("{ this is not json,,, ")
m.write_rule("Bash(echo hi)", {"cwd": d}, cfg)
want("won't clobber corrupt settings", open(corrupt).read().startswith("{ this is not json"))

# re-review MEDIUM: a string mcp_autoallow_servers must not become a substring test
strcfg = copy.deepcopy(cfg); strcfg["approval"]["mcp_autoallow_servers"] = "claude_ai_Gmail"
want("string allowlist ignored",  not m.is_read_only_mcp("mcp__claude_ai_Gmail__get_x", strcfg))

# re-review MEDIUM: exec/run-style mutating tokens are blocked even under opt-in
want("get_exec_result blocked",   not m.is_read_only_mcp("mcp__claude_ai_Gmail__get_exec_result", optin))
want("list_run_artifacts blocked",not m.is_read_only_mcp("mcp__claude_ai_Gmail__list_run_artifacts", optin))

# re-review LOW: prefix 'Always' rule respects a word boundary
want("prefix rule word boundary", not m.pattern_matches("Bash", {"command":"git logger x"}, "Bash(git log:*)"))
want("prefix rule still matches",     m.pattern_matches("Bash", {"command":"git log --oneline"}, "Bash(git log:*)"))

# re-review open question: a deny rule is enforced even in bypassPermissions mode
m.load_patterns = lambda cwd, kind: (["Bash(rm -rf /)"] if kind == "deny" else [])
try:
    d2 = m.evaluate({"tool_name":"Bash","tool_input":{"command":"rm -rf /"},
                     "permission_mode":"bypassPermissions","cwd":sys.argv[1]}, cfg)
    want("deny enforced in bypass mode", d2["action"] == "deny")
finally:
    m.load_patterns = orig

# v0.2: Claude reads a trailing * as a prefix rule — never mint one from 'Always'
want("no rule minted for trailing-*", m.make_rule("Bash", {"command": "rm -rf node_modules/*"}, cfg) is None)

# Junk/unsafe-rule refusal must hold in BOTH always-modes. A heredoc/multiline,
# a CR-spliced command, or an oversized one can never safely become a rule: exact
# minting is settings clutter that never matches again; prefix minting is worse —
# the 2-word head would splice across the newline/CR (regression: prefix used to
# skip this guard and mint e.g. 'Bash(cd /tmp:*)' out of a heredoc). The prompt
# flow hides the Always button off this same None.
cfg_exact  = copy.deepcopy(cfg); cfg_exact["approval"]["bash_always_mode"]  = "exact"
cfg_prefix = copy.deepcopy(cfg); cfg_prefix["approval"]["bash_always_mode"] = "prefix"
for _mode, _c in (("exact", cfg_exact), ("prefix", cfg_prefix)):
    want(f"[{_mode}] no rule minted for multiline", m.make_rule("Bash", {"command": "cd /tmp\npython3 - <<'PY'\nprint(1)\nPY"}, _c) is None)
    want(f"[{_mode}] no rule minted for CR",        m.make_rule("Bash", {"command": "echo a\rrm -rf /"}, _c) is None)
    want(f"[{_mode}] no rule minted over 200 chars", m.make_rule("Bash", {"command": "echo " + "x" * 200}, _c) is None)
    want(f"[{_mode}] 200-char boundary still mints", m.make_rule("Bash", {"command": "e" + "x" * 199}, _c) is not None)
# Minting form is mode-specific: exact grants the whole command; prefix grants
# the first two words as a word-boundary prefix rule.
want("exact mode mints the exact command",  m.make_rule("Bash", {"command": "npm run build"}, cfg_exact)  == "Bash(npm run build)")
want("prefix mode mints the 2-word prefix", m.make_rule("Bash", {"command": "npm run build"}, cfg_prefix) == "Bash(npm run:*)")

# v0.2: Claude's documented pattern forms are recognized (fewer needless toasts)
want("bash 'cmd *' prefix form",      m.pattern_matches("Bash", {"command":"npm run build"}, "Bash(npm run *)"))
want("bash 'cmd *' word boundary", not m.pattern_matches("Bash", {"command":"npm runner"}, "Bash(npm run *)"))
want("project-root path anchor",      m.pattern_matches("Edit", {"file_path": sys.argv[1] + "/src/a.ts"}, "Edit(/src/**)", sys.argv[1]))
want("relative path pattern",         m.pattern_matches("Edit", {"file_path": sys.argv[1] + "/src/a.ts"}, "Edit(src/**)", sys.argv[1]))
want("**/ matches zero dirs",         m.pattern_matches("Edit", {"file_path": sys.argv[1] + "/a.ts"}, "Edit(/**/*.ts)", sys.argv[1]))
want("path anchor is not absolute", not m.pattern_matches("Edit", {"file_path": "/src/a.ts"}, "Edit(/src/**)", sys.argv[1]))
want("mcp wildcard rule",             m.pattern_matches("mcp__gh__get_issue", {}, "mcp__gh__get_*"))
want("mcp wildcard scoped",       not m.pattern_matches("mcp__gh__create_issue", {}, "mcp__gh__get_*"))

# critic HIGH: a literal '*' in a directory name must never become a wildcard
want("cwd with * stays literal",  not m.pattern_matches("Edit", {"file_path": "/tmp/projYYYx/secret.txt"}, "Edit(secret.txt)", "/tmp/proj*x"))
want("cwd with * matches itself",     m.pattern_matches("Edit", {"file_path": "/tmp/proj*x/secret.txt"}, "Edit(secret.txt)", "/tmp/proj*x"))

# critic MEDIUM: rules for commands ending in ')' must round-trip
paren_cmd = {"command": "git log $(git rev-parse HEAD)"}
paren_rule = m.make_rule("Bash", paren_cmd, cfg)
want("paren command round-trips", bool(paren_rule) and m.pattern_matches("Bash", paren_cmd, paren_rule))

# v0.2: last-message fallback parses the transcript JSONL (skips sidechains/tool_use)
tpath = os.path.join(tempfile.mkdtemp(), "t.jsonl")
with open(tpath, "w") as f:
    f.write(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}) + "\n")
    f.write("not json\n")
    f.write(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}) + "\n")
    f.write(json.dumps({"type":"assistant","isSidechain":True,"message":{"content":[{"type":"text","text":"subagent noise"}]}}) + "\n")
    f.write(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"the real last message"}]}}) + "\n")
want("transcript fallback finds last text", m.last_message_from_transcript(tpath) == "the real last message")
want("transcript fallback survives ENOENT", m.last_message_from_transcript("/nope/nothing.jsonl") == "")

# v0.3: interaction tools — deny keeps its hard floor; answers must round-trip
# the EXACT question/option strings (truncated button labels must never leak
# into updatedInput, or Claude Code won't recognise the answer)
q = {"questions": [{"question": "Which authentication approach should we take?",
                    "header": "Auth",
                    "options": [{"label": "JWT with long refresh tokens"},
                                {"label": "Server-side sessions"}],
                    "multiSelect": False}]}
m.load_patterns = lambda cwd, kind: (["AskUserQuestion"] if kind == "deny" else [])
try:
    d3 = m.evaluate({"tool_name": "AskUserQuestion", "tool_input": q,
                     "permission_mode": "default", "cwd": sys.argv[1]}, cfg)
    want("deny beats question surface", d3["action"] == "deny")
finally:
    m.load_patterns = orig
d4 = m.evaluate({"tool_name": "AskUserQuestion", "tool_input": q,
                 "permission_mode": "dontAsk", "cwd": sys.argv[1]}, cfg)
want("question surfaces even in dontAsk", d4["action"] == "question")
want("question keeps exact answer strings",
     d4["items"][0]["question"] == q["questions"][0]["question"]
     and d4["items"][0]["options"] == ["JWT with long refresh tokens", "Server-side sessions"])
offcfg = copy.deepcopy(cfg); offcfg["approval"]["surface_plans"] = False
d5 = m.evaluate({"tool_name": "ExitPlanMode", "tool_input": {"plan": "x"},
                 "permission_mode": "plan", "cwd": sys.argv[1]}, offcfg)
want("surface_plans=false defers", d5["action"] == "defer")

# v0.5: the option-list layout must never damage answer integrity.
# Descriptions ride index-aligned with options; unknown option keys (real
# transcripts carry "preview" payloads with multi-line ASCII art) never leak;
# display copies are sanitized so the \x1f field separator can't misalign a
# row against its exit-code index.
q2 = {"questions": [{"question": "Which release flow?",
                     "header": "Release",
                     "options": [{"label": "Commits + v0.4.0 tag (Recommended)",
                                  "description": "Tag the release now.",
                                  "preview": "ASCII-ART\nJUNK\x1fPAYLOAD"},
                                 {"label": "Commits + both tags",
                                  "description": "Tag v0.4.0 and v0.5.0."},
                                 "Bare string option"],
                     "multiSelect": False}]}
d6 = m.evaluate({"tool_name": "AskUserQuestion", "tool_input": q2,
                 "permission_mode": "default", "cwd": sys.argv[1]}, cfg)
i6 = d6["items"][0]
want("question w/ descriptions toasts", d6["action"] == "question")
want("options keep exact raw strings",
     i6["options"] == ["Commits + v0.4.0 tag (Recommended)", "Commits + both tags",
                       "Bare string option"])
want("descriptions index-aligned (bare option = '')",
     i6["descriptions"] == ["Tag the release now.", "Tag v0.4.0 and v0.5.0.", ""])
want("unknown option keys never leak", "ASCII-ART" not in repr(d6))
want("argv buttons stay stale-binary safe",
     i6["buttons"] == [m.trunc(m._display_line(o), 16) for o in i6["options"]])

# critic HIGH: a whitespace/control-only label sanitizes to an empty
# NOTI_OPTIONS field, and ONE empty field would kick the whole card off the
# list layout onto the 3-button fallback — silently hiding a real 4th option.
# The degenerate option must be dropped alone, everything real kept.
qws = {"questions": [{"question": "Pick one",
                      "options": [{"label": "Alpha"},
                                  {"label": " ", "description": "ghost"},
                                  {"label": "\x01\x02"},
                                  {"label": "Delta (Recommended)"}],
                      "multiSelect": False}]}
dws = m.evaluate({"tool_name": "AskUserQuestion", "tool_input": qws,
                  "permission_mode": "default", "cwd": sys.argv[1]}, cfg)
iws = dws["items"][0]
want("degenerate labels dropped, real options kept",
     dws["action"] == "question" and iws["options"] == ["Alpha", "Delta (Recommended)"])
want("descriptions realigned after the drop", iws["descriptions"] == ["", ""])
want("no empty NOTI_OPTIONS field can reach the binary",
     all(f for f in m._toast_env(5, None, "top-right",
                                 options=iws["options"])["NOTI_OPTIONS"].split("\x1f")))

want("_display_line strips controls", m._display_line("a\x1fb\nc\x00d") == "a b c d")
envd = m._toast_env(5, None, "top-right",
                    options=["x\x1fy", "b"], descs=["d1\x1fd2", ""])
want("embedded \\x1f can't misalign options", envd["NOTI_OPTIONS"] == "x y\x1fb")
want("embedded \\x1f can't misalign descs",   envd["NOTI_DESCS"] == "d1 d2\x1f")
want("desc arity mismatch not sent",
     "NOTI_DESCS" not in m._toast_env(5, None, "top-right", options=["a", "b"], descs=["only-one"]))

# a stray exported NOTI_OPTIONS must never flip a permission prompt into the
# list layout with labels noti never chose
os.environ["NOTI_OPTIONS"] = "evil\x1fpayload"; os.environ["NOTI_DESCS"] = "x\x1fy"
try:
    env2 = m._toast_env(5, None, "top-right")
    want("inherited NOTI_OPTIONS/DESCS scrubbed",
         "NOTI_OPTIONS" not in env2 and "NOTI_DESCS" not in env2)
finally:
    del os.environ["NOTI_OPTIONS"]; del os.environ["NOTI_DESCS"]

# answer round-trip at the new 4-option arity: exit code 3 -> EXACT 4th option
# via updatedInput; esc/timeout (124) and junk exit codes emit NO decision
import io, contextlib
q4 = {"questions": [{"question": "Pick one?",
                     "options": [{"label": "Alpha"}, {"label": "Beta"},
                                 {"label": "Gamma"}, {"label": "Delta (Recommended)"}],
                     "multiSelect": False}]}
d7 = m.evaluate({"tool_name": "AskUserQuestion", "tool_input": q4,
                 "permission_mode": "default", "cwd": sys.argv[1]}, cfg)
_save_ask = m.toast_ask
def _run_prompt(rc, text="", use_cfg=cfg):
    calls = []
    def fake(title, message, buttons, timeout, corner, slot, **k):
        calls.append({"timeout": timeout, "project": k.get("project", ""),
                      "other": k.get("other", None)})
        return (rc, text)
    m.toast_ask = fake
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            m.prompt_question({"tool_name": "AskUserQuestion", "tool_input": q4,
                               "session_id": "t", "cwd": sys.argv[1]}, use_cfg, dict(d7))
    finally:
        m.toast_ask = _save_ask
    return buf.getvalue(), calls
out3, calls3 = _run_prompt(3)
want("rc=3 answers with exact 4th option",
     '"Delta (Recommended)"' in out3 and '"permissionDecision": "allow"' in out3)
# a single-question card must be byte-identical to the pre-multi design: no
# "1 of 1" progress suffix may ever appear on its eyebrow
want("single question card has no progress suffix", " of " not in calls3[0]["project"])
want("rc=124 (esc/timeout) emits no decision", _run_prompt(124)[0].strip() == "")
want("junk exit code emits no decision", _run_prompt(7)[0].strip() == "")

# v0.5.x: multi-question calls toast sequentially and answer ALL-or-nothing —
# a partial `answers` dict would mark the omitted questions answered (behavior
# undocumented upstream), so an esc/timeout on ANY card must discard the set.
# The set shares ONE deadline: the installed hook timeout (ask+30) blocks the
# tool call outright when exceeded, so per-card budgets are forbidden.
qm = {"questions": [
    {"question": "Q-one?", "header": "One",
     "options": [{"label": "A1"}, {"label": "B1"}], "multiSelect": False},
    {"question": "Q-two?", "header": "Two",
     "options": [{"label": "A2"}, {"label": "B2"}, {"label": "C2"}], "multiSelect": False},
    {"question": "Q-three?",
     "options": [{"label": "A3"}, {"label": "B3"}], "multiSelect": False}]}
dm = m.evaluate({"tool_name": "AskUserQuestion", "tool_input": qm,
                 "permission_mode": "default", "cwd": sys.argv[1]}, cfg)
want("multi-question call toasts with one item per question",
     dm["action"] == "question" and len(dm["items"]) == 3)

# the fake clock advances `advance` seconds inside each card, so deadline
# shrinkage is OBSERVABLE — a per-card-budget mutant (fresh ask_timeout per
# card, which would blow through the ask+30 hook timeout Claude Code kills
# hooks at) fails the exact-sequence assertion below
_real_mono = m.time.monotonic
def _run_multi(rcs, use_cfg=cfg, advance=10.0):
    # entries are (rc, stdout_text) pairs; a bare int means stdout ""
    seq = [(r, "") if isinstance(r, int) else r for r in rcs]; calls = []
    clock = {"t": 1000.0}
    def fake(title, message, buttons, timeout, corner, slot, **k):
        calls.append({"timeout": timeout, "project": k.get("project", ""),
                      "other": k.get("other", None)})
        clock["t"] += advance
        return seq.pop(0)
    m.toast_ask = fake
    m.time.monotonic = lambda: clock["t"]
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            m.prompt_question({"tool_name": "AskUserQuestion", "tool_input": qm,
                               "session_id": "t", "cwd": sys.argv[1]}, use_cfg, dict(dm))
    finally:
        m.toast_ask = _save_ask
        m.time.monotonic = _real_mono
    return buf.getvalue(), calls

out_all, calls = _run_multi([1, 2, 0])
ans = json.loads(out_all)["hookSpecificOutput"]["updatedInput"]["answers"]
want("multi answers complete + exact strings",
     ans == {"Q-one?": "B1", "Q-two?": "C2", "Q-three?": "A3"})
want("progress eyebrow counts the cards",
     calls[0]["project"].endswith("1 of 3") and calls[2]["project"].endswith("3 of 3"))
_ask = float(cfg["toast"]["ask_timeout_seconds"])
want("set shares ONE shrinking deadline (never a fresh per-card budget)",
     [c["timeout"] for c in calls] == [_ask, _ask - 10.0, _ask - 20.0])
out_esc, calls_esc = _run_multi([1, 124, 0])
want("esc mid-set discards ALL answers (no partial updatedInput)",
     out_esc.strip() == "" and len(calls_esc) == 2)
out_dry, calls_dry = _run_multi([0, 0, 0], advance=50.0)
want("mid-set budget exhaustion discards the set",
     out_dry.strip() == "" and len(calls_dry) == 2)
tinycfg = copy.deepcopy(cfg); tinycfg["toast"]["ask_timeout_seconds"] = 0
out_tiny, calls_tiny = _run_multi([0, 0, 0], use_cfg=tinycfg)
want("pathological tiny config still shows the first card (4s floor)",
     out_tiny.strip() == "" and len(calls_tiny) == 1 and calls_tiny[0]["timeout"] == 4.0)

# duplicate question texts would collapse into one answers key — a partial
# answer in disguise; the whole call must fall to the notice
qdup = {"questions": [
    {"question": "Same?", "options": [{"label": "A"}, {"label": "B"}]},
    {"question": "Same?", "options": [{"label": "C"}, {"label": "D"}]}]}
want("duplicate question texts -> notice",
     m.evaluate({"tool_name": "AskUserQuestion", "tool_input": qdup,
                 "permission_mode": "default", "cwd": sys.argv[1]}, cfg)["action"] == "notice")

# v0.6: free-text "Other" on question cards. rc == RC_OTHER (a FIXED sentinel,
# never len(options)) is the one path where stdout is the answer, guarded by
# the question_other kill-switch, an emptiness check (spike-pinned: an empty
# updatedInput answer is silently swallowed upstream — the terminal never
# re-asks), and a C0 control strip. The row is PURE UI: the decision dict and
# NOTI_OPTIONS arity are byte-identical to v0.5.
want("RC_OTHER clear of the code space",
     m.RC_OTHER > 4 and m.RC_OTHER not in (64, 70, 124))

envo = m._toast_env(5, None, "top-right", options=["a", "b"], other=True)
want("other=True sets NOTI_OTHER=1", envo.get("NOTI_OTHER") == "1")
want("other=False -> NOTI_OTHER absent",
     "NOTI_OTHER" not in m._toast_env(5, None, "top-right", options=["a", "b"]))
want("other without options -> NOTI_OTHER absent",
     "NOTI_OTHER" not in m._toast_env(5, None, "top-right", other=True))
os.environ["NOTI_OTHER"] = "1"
try:
    want("inherited NOTI_OTHER scrubbed",
         "NOTI_OTHER" not in m._toast_env(5, None, "top-right"))
finally:
    del os.environ["NOTI_OTHER"]

def _answers(out):
    return json.loads(out)["hookSpecificOutput"]["updatedInput"]["answers"]

# single-question card: the full (rc, stdout) resolution matrix
out_o, calls_o = _run_prompt(m.RC_OTHER, "some free text")
want("free text -> exact string in answers",
     _answers(out_o) == {"Pick one?": "some free text"})
want("card offered the row (other=True observed)", calls_o[0]["other"] is True)
want("empty free answer -> no decision",
     _run_prompt(m.RC_OTHER, "")[0].strip() == "")
want("whitespace-only free answer -> no decision",
     _run_prompt(m.RC_OTHER, "   ")[0].strip() == "")
want("outer whitespace stripped, interior exact",
     _answers(_run_prompt(m.RC_OTHER, "  spaced  ")[0]) == {"Pick one?": "spaced"})
want("unicode survives byte-exact",
     _answers(_run_prompt(m.RC_OTHER, "café ☕")[0]) == {"Pick one?": "café ☕"})
want("C0 controls stripped from a pasted answer",
     _answers(_run_prompt(m.RC_OTHER, "a\x1b[31mb\x00c")[0]) == {"Pick one?": "a[31mbc"})
# display helpers must never touch an answer: a tab, a run of spaces, and
# >120 chars all survive byte-exact (kills the trunc()/_display_line()-on-
# typed mutants, which are no-ops on short single-spaced fixtures)
long_raw = "a\tb  c" + "x" * 300
want("long/tabbed answer survives byte-exact",
     _answers(_run_prompt(m.RC_OTHER, long_raw)[0]) == {"Pick one?": long_raw})
# kills any "outside-range-but-has-stdout" heuristic: stdout is ONLY an
# answer at rc == RC_OTHER — below it (7), and ABOVE it too (124/64 with a
# dirty stdout: a binary that printed a diagnostic before dying must never
# have that diagnostic submitted as the user's answer; kills rc >= RC_OTHER)
want("junk rc with stdout -> no decision", _run_prompt(7, "ghost")[0].strip() == "")
want("rc=124 with dirty stdout -> no decision",
     _run_prompt(124, "ghost")[0].strip() == "")
want("rc=64 with dirty stdout -> no decision",
     _run_prompt(64, "usage: noti-toast ask|summary|pet ...")[0].strip() == "")
# display copy must never be the answer on the index path
want("option rc answers from the LIST, never stdout",
     _answers(_run_prompt(0, "Mangled Display Label")[0]) == {"Pick one?": "Alpha"})
# the kill-switch pins BOTH sides: rc=10 stays junk AND the row is never offered
offo = copy.deepcopy(cfg); offo["approval"]["question_other"] = False
out_off, calls_off = _run_prompt(m.RC_OTHER, "rogue text", use_cfg=offo)
want("question_other=False rejects rc=10", out_off.strip() == "")
want("question_other=False never offers the row", calls_off[0]["other"] is False)

# multi-question: free-text cards join the all-or-nothing set
out_mo, calls_mo = _run_multi([(1, ""), (m.RC_OTHER, "my custom take"), (0, "")])
want("mixed option/free-text set completes exactly",
     _answers(out_mo) == {"Q-one?": "B1", "Q-two?": "my custom take", "Q-three?": "A3"})
# typing earns no fresh budget: the shared deadline shrinks through a
# free-text card exactly as through option cards (the hook timeout ask+30
# still hard-blocks the tool call — see the v0.5.x block above)
want("free-text card still shares ONE shrinking deadline",
     [c["timeout"] for c in calls_mo] == [_ask, _ask - 10.0, _ask - 20.0])
out_bail, calls_bail = _run_multi([(m.RC_OTHER, "typed then bailed"), (124, "")])
want("esc after a free-text answer discards the set",
     out_bail.strip() == "" and len(calls_bail) == 2)
out_em, calls_em = _run_multi([(m.RC_OTHER, ""), (0, ""), (0, "")])
want("empty free answer aborts the set at once",
     out_em.strip() == "" and len(calls_em) == 1)

# the Other row is PURE UI: policy output for the 4-option fixture is
# byte-identical to v0.5 — no synthetic 5th option anywhere
want("no synthetic Other in the decision dict",
     len(d7["items"][0]["options"]) == 4
     and d7["items"][0]["options"][3] == "Delta (Recommended)")
want("no synthetic Other in NOTI_OPTIONS arity",
     len(m._toast_env(5, None, "top-right", options=d7["items"][0]["options"],
                      other=True)["NOTI_OPTIONS"].split("\x1f")) == 4)

# v0.4: evaluate() is TOTAL against malformed / forward-incompatible payloads.
# Claude Code's hook JSON has shifted across versions and a stranger may run an
# older/newer build — every odd shape must DEGRADE (defer, or a safe prompt),
# never traceback. A raise here would (in the hook path) fail open, but keeping
# the pure function total protects `noti decide` and any future caller.
CWD = sys.argv[1]
def ev(p):
    return m.evaluate(p, cfg)["action"]
want("non-dict payload defers",        ev("not a dict") == "defer")
want("non-str tool_name defers",       ev({"tool_name": 123, "tool_input": {}, "cwd": CWD}) == "defer")
want("missing tool_name defers",       ev({"tool_input": {"command": "ls"}, "cwd": CWD}) == "defer")
want("non-dict tool_input -> prompt",  ev({"tool_name": "Bash", "tool_input": "rm -rf /", "cwd": CWD}) == "prompt")
want("list tool_input -> prompt",      ev({"tool_name": "Bash", "tool_input": [1, 2], "cwd": CWD}) == "prompt")
want("missing permission_mode allows safe", ev({"tool_name": "Bash", "tool_input": {"command": "git status"}, "cwd": CWD}) == "allow")
want("missing cwd doesn't crash",      ev({"tool_name": "Bash", "tool_input": {"command": "git status"}}) == "allow")
want("questions as dict -> notice",    ev({"tool_name": "AskUserQuestion", "tool_input": {"questions": {"x": 1}}, "cwd": CWD}) == "notice")
want("options as bare strings -> question", ev({"tool_name": "AskUserQuestion", "tool_input": {"questions": [{"question": "Q?", "options": ["A", "B"]}]}, "cwd": CWD}) == "question")
want("bash without command -> prompt", ev({"tool_name": "Bash", "tool_input": {}, "cwd": CWD}) == "prompt")
# v0.4 F13 (HIGH): a non-string nested tool_input field must not crash the pure
# path — it degrades to a safe prompt, not a traceback (previously AttributeError)
want("int command -> prompt (no crash)", ev({"tool_name": "Bash", "tool_input": {"command": 123}, "cwd": CWD}) == "prompt")
want("list file_path -> prompt (no crash)", ev({"tool_name": "Write", "tool_input": {"file_path": ["x"]}, "cwd": CWD}) == "prompt")
want("dict url -> prompt (no crash)",    ev({"tool_name": "WebFetch", "tool_input": {"url": {"x": 1}}, "cwd": CWD}) == "prompt")
# v0.4 F14 (MEDIUM): with cwd absent, a path-anchored allow rule must NOT auto-
# allow (it could out-vote a deny mis-anchored to the same guessed cwd)
_save2 = m.load_patterns
m.load_patterns = lambda cwd, kind: (["Edit(//tmp/anywhere/secret.txt)"] if kind == "allow" else [])
try:
    want("no-cwd path allow does not auto-allow",
         m.evaluate({"tool_name": "Write", "tool_input": {"file_path": "/tmp/anywhere/secret.txt"}}, cfg)["action"] == "prompt")
    want("known-cwd path allow still allows",
         m.evaluate({"tool_name": "Write", "tool_input": {"file_path": "/tmp/anywhere/secret.txt"},
                     "cwd": CWD}, cfg)["action"] == "allow")
finally:
    m.load_patterns = _save2

# Pet state is opt-in and must stay fail-open: disabled config writes nothing;
# enabled hooks publish tiny per-session files without changing the decision
# path. The prompt case fakes a timeout so no GUI launches and the standing
# summons intentionally remains waiting for the terminal fallback.
pet_dir = tempfile.mkdtemp()
pet_payload = {"tool_name": "Bash", "tool_input": {"command": "git status"},
               "permission_mode": "default", "cwd": CWD, "session_id": "pet/safe"}
pet_off = copy.deepcopy(cfg)
pet_off["pet"]["enabled"] = False
pet_off["pet"]["state_dir"] = pet_dir
m.pet_record(pet_payload, pet_off, "waiting")
want("pet.enabled=False writes no state", not os.listdir(pet_dir))

pet_on = copy.deepcopy(cfg)
pet_on["pet"]["enabled"] = True
pet_on["pet"]["state_dir"] = pet_dir
m.pet_record(pet_payload, pet_on, "waiting")
pet_files = os.listdir(pet_dir)
pet_data = json.load(open(os.path.join(pet_dir, pet_files[0])))
want("pet state file is sanitized JSON",
     pet_files == ["pet_safe.json"] and pet_data["state"] == "waiting"
     and pet_data["project"] == os.path.basename(CWD))

hook_dir = tempfile.mkdtemp()
hook_cfg = copy.deepcopy(cfg)
hook_cfg["pet"]["enabled"] = True
hook_cfg["pet"]["state_dir"] = hook_dir
_load_config, _toast_ask, _acquire_slot, _release_slot = (
    m.load_config, m.toast_ask, m.acquire_slot, m.release_slot)
try:
    m.load_config = lambda: hook_cfg
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = m.hook_pretooluse(pet_payload)
    hook_state = json.load(open(os.path.join(hook_dir, "pet_safe.json")))
    want("safe pretool writes running pet state",
         rc == 0 and hook_state["state"] == "running"
         and json.loads(out.getvalue())["hookSpecificOutput"]["permissionDecision"] == "allow")

    m.toast_ask = lambda *a, **kw: (124, "")
    m.acquire_slot = lambda *a, **kw: 0
    m.release_slot = lambda *a, **kw: None
    wait_payload = {"tool_name": "Bash", "tool_input": {"command": "rm -rf build"},
                    "permission_mode": "default", "cwd": CWD, "session_id": "pet-wait"}
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = m.hook_pretooluse(wait_payload)
    wait_state = json.load(open(os.path.join(hook_dir, "pet-wait.json")))
    want("prompt fallback leaves pet waiting",
         rc == 0 and wait_state["state"] == "waiting"
         and json.loads(out.getvalue())["hookSpecificOutput"]["permissionDecision"] == "ask")
finally:
    m.load_config, m.toast_ask, m.acquire_slot, m.release_slot = (
        _load_config, _toast_ask, _acquire_slot, _release_slot)

# Pet-attached prompts: when a live pet hosts the toast, the interactive card
# grows out of the crab instead of a separate corner toast. The gate is
# opt-in-enabled + kill-switch + a VERIFIED-LIVE pet; anything else must fall
# back to the corner (never attach a prompt to a crab that isn't on screen).
_pir = m.pet_is_running
try:
    attach_cfg = copy.deepcopy(cfg)
    attach_cfg["pet"]["enabled"] = True
    attach_cfg["pet"]["attach_prompts"] = True
    m.pet_is_running = lambda: 4321
    want("attach when pet enabled, switch on, and running",
         m._attach_prompts(attach_cfg) is True)
    m.pet_is_running = lambda: None
    want("no attach when the pet pid is not verified-live",
         m._attach_prompts(attach_cfg) is False)
    m.pet_is_running = lambda: 4321
    off_switch = copy.deepcopy(attach_cfg)
    off_switch["pet"]["attach_prompts"] = False
    want("no attach when the attach kill-switch is off",
         m._attach_prompts(off_switch) is False)
    disabled = copy.deepcopy(cfg)
    disabled["pet"]["enabled"] = False
    want("no attach when the pet is disabled", m._attach_prompts(disabled) is False)
finally:
    m.pet_is_running = _pir

# The attach env pair: NOTI_ATTACH + the pet dir it reads .anchor from, and NO
# corner slot dir (attached cards don't stack in the column). A stray inherited
# NOTI_ATTACH is scrubbed unless THIS call opted in — same discipline as the
# NOTI_OPTIONS/NOTI_OTHER scrubs, so an export can't force-attach a toast.
env_a = m._toast_env(90, None, "top-right", attach=True, pet_dir="/tmp/petdir")
want("attach env sets NOTI_ATTACH + pet dir, no corner slot dir",
     env_a.get("NOTI_ATTACH") == "1" and env_a.get("NOTI_PET_STATE_DIR") == "/tmp/petdir"
     and "NOTI_SLOT_DIR" not in env_a)
want("unattached env carries no NOTI_ATTACH",
     "NOTI_ATTACH" not in m._toast_env(90, None, "top-right"))
os.environ["NOTI_ATTACH"] = "1"
try:
    want("stray inherited NOTI_ATTACH is scrubbed when not attaching",
         "NOTI_ATTACH" not in m._toast_env(90, None, "top-right", attach=False))
finally:
    os.environ.pop("NOTI_ATTACH", None)

# The prompt path honors attach: it must pass attach=True + a pet_dir, hand the
# toast slot=None, and NOT acquire a corner slot (the pet's spot is the position).
_attach_o, _toast_o, _acq_o, _rel_o, _lc_o = (
    m._attach_prompts, m.toast_ask, m.acquire_slot, m.release_slot, m.load_config)
seen = {}
acq_calls = []
def _cap_toast(*a, **kw):
    seen["attach"] = kw.get("attach")
    seen["pet_dir"] = kw.get("pet_dir")
    seen["slot"] = a[5] if len(a) > 5 else kw.get("slot")   # title,msg,buttons,timeout,corner,slot
    return (124, "")
try:
    m.load_config = lambda: hook_cfg
    m._attach_prompts = lambda c: True
    m.toast_ask = _cap_toast
    m.acquire_slot = lambda *a, **kw: (acq_calls.append(1), 0)[1]
    m.release_slot = lambda *a, **kw: None
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        m.hook_pretooluse(wait_payload)
    want("attached prompt passes attach=True/slot=None and skips the corner slot",
         seen.get("attach") is True and seen.get("slot") is None
         and seen.get("pet_dir") and not acq_calls)
finally:
    m._attach_prompts, m.toast_ask, m.acquire_slot, m.release_slot, m.load_config = (
        _attach_o, _toast_o, _acq_o, _rel_o, _lc_o)

# The plan and question paths honor attach the same way the prompt path does —
# same attach=True/slot=None/pet_dir contract, so the pet hosts every kind of
# interactive prompt, not just approvals.
_attach_o2, _toast_o2 = m._attach_prompts, m.toast_ask
plan_seen, q_seen = {}, {}
def _cap_plan(*a, **kw):
    plan_seen.update(attach=kw.get("attach"), pet_dir=kw.get("pet_dir"),
                     slot=(a[5] if len(a) > 5 else kw.get("slot")))
    return (0, "Approve")
def _cap_q(*a, **kw):
    q_seen.update(attach=kw.get("attach"), pet_dir=kw.get("pet_dir"),
                  slot=(a[5] if len(a) > 5 else kw.get("slot")))
    return (0, "")
try:
    m._attach_prompts = lambda c: True
    m.toast_ask = _cap_plan
    with contextlib.redirect_stdout(io.StringIO()):
        m.prompt_plan(pet_payload, hook_cfg, {"title": "Plan", "message": "ready", "project": "noti"})
    want("attached plan passes attach=True/slot=None",
         plan_seen.get("attach") is True and plan_seen.get("slot") is None and plan_seen.get("pet_dir"))
    m.toast_ask = _cap_q
    qd = {"project": "noti", "items": [{"title": "Q", "message": "m", "buttons": ["1", "2"],
          "options": ["A", "B"], "descriptions": ["", ""], "question": "q?"}]}
    with contextlib.redirect_stdout(io.StringIO()):
        m.prompt_question(pet_payload, hook_cfg, qd)
    want("attached question passes attach=True/slot=None",
         q_seen.get("attach") is True and q_seen.get("slot") is None and q_seen.get("pet_dir"))
finally:
    m._attach_prompts, m.toast_ask = _attach_o2, _toast_o2

for raw, label in [("not json", "garbage hook stdin exits 0"),
                   ("[]", "non-dict hook payload exits 0")]:
    old_stdin = sys.stdin
    sys.stdin = io.StringIO(raw)
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            rc = m.cmd_hook(type("Args", (), {"event": "pretooluse"})())
        want(label, rc == 0 and out.getvalue() == "")
    finally:
        sys.stdin = old_stdin

# hook_stop publishes 'done' BEFORE the summary.enabled early-return, so the
# pet's end-of-turn clear of a standing 'waiting' works even with summaries off.
import pathlib
done_dir = tempfile.mkdtemp()
done_cfg = copy.deepcopy(cfg)
done_cfg["pet"]["enabled"] = True
done_cfg["pet"]["state_dir"] = done_dir
done_cfg["summary"]["enabled"] = False
_lc = m.load_config
try:
    m.load_config = lambda: done_cfg
    rc = m.hook_stop({"cwd": CWD, "session_id": "done-sess"})
    done_state = json.load(open(os.path.join(done_dir, "done-sess.json")))
    want("hook_stop writes done pet state even with summaries off",
         rc == 0 and done_state["state"] == "done")
finally:
    m.load_config = _lc

# StopFailure: the turn died. The handler must (1) stand the pet's failed
# summons, (2) read-AND-CLEAR the dead turn's tally so it can't leak into the
# next turn's summary, (3) map documented reasons to copy and render unknown
# reasons verbatim (control-stripped), (4) honor the alerts.stop_failure
# kill-switch at hook time — and always exit 0.
sf_dir = tempfile.mkdtemp()
sf_cfg = copy.deepcopy(cfg)
sf_cfg["pet"]["enabled"] = True
sf_cfg["pet"]["state_dir"] = sf_dir
_lc, _ts = m.load_config, m.toast_summary
toasts = []
try:
    m.load_config = lambda: sf_cfg
    m.toast_summary = lambda *a, **kw: toasts.append((a, kw))
    m.tally_record({"tool_name": "Bash", "tool_input": {"command": "x"},
                    "session_id": "sf-sess"})
    rc = m.hook_stopfailure({"cwd": CWD, "session_id": "sf-sess",
                             "reason": "rate_limit"})
    sf_state = json.load(open(os.path.join(sf_dir, "sf-sess.json")))
    want("stopfailure stands the pet's failed summons",
         rc == 0 and sf_state["state"] == "failed")
    want("stopfailure toasts the mapped reason as kind=error",
         len(toasts) == 1 and toasts[0][0][1] == "Turn ended: rate limited"
         and toasts[0][1].get("kind") == "error")
    want("stopfailure footer carries the dead turn's tally",
         toasts[0][1].get("footer", "") == "after ran 1 command")
    rc = m.hook_stopfailure({"cwd": CWD, "session_id": "sf-sess",
                             "reason": "weird_new_reason\x1bjunk"})
    want("unknown reason renders verbatim, control-stripped",
         rc == 0 and toasts[-1][0][1] == "Turn ended: weird_new_reason junk")
    want("first read CLEARED the tally (no leak into later toasts)",
         toasts[-1][1].get("footer", "") == "")
    rc = m.hook_stopfailure({"cwd": CWD, "session_id": "sf-sess"})
    want("missing reason -> generic copy",
         rc == 0 and toasts[-1][0][1] == "Turn ended unexpectedly")
    toasts.clear()
    sf_cfg["alerts"]["stop_failure"] = False
    os.unlink(os.path.join(sf_dir, "sf-sess.json"))
    rc = m.hook_stopfailure({"cwd": CWD, "session_id": "sf-sess",
                             "reason": "server_error"})
    sf_state = json.load(open(os.path.join(sf_dir, "sf-sess.json")))
    want("kill-switch silences the toast but still stands the pet",
         rc == 0 and not toasts and sf_state["state"] == "failed")
finally:
    m.load_config, m.toast_summary = _lc, _ts

# A hostile session_id (semi-trusted hook payload) must never place a state file
# outside pet.state_dir, and must always yield a non-empty sanitized name.
hostile_cfg = copy.deepcopy(cfg)
hostile_cfg["pet"]["state_dir"] = tempfile.mkdtemp()
hostile_root = os.path.realpath(hostile_cfg["pet"]["state_dir"])
hostile_ok = True
for sid in ["../../evil", "/etc/passwd", "", "...", "._.", "a" * 500,
            "../../../.claude/settings", "a/b/c"]:
    rp = os.path.realpath(str(m.pet_session_path({"session_id": sid}, hostile_cfg)))
    base = os.path.basename(rp)
    hostile_ok = hostile_ok and os.path.dirname(rp) == hostile_root \
        and base.endswith(".json") and len(base) > len(".json")
want("hostile session_id can't escape pet.state_dir", hostile_ok)

# Regression (pre-existing, adjacent): tally paths must sanitize session_id the
# same way — a raw id like "../../pwned" used to escape TALLY_DIR and clobber an
# arbitrary .json via atomic_write_json/os.replace.
tally_tmp = tempfile.mkdtemp()
_TALLY = m.TALLY_DIR
try:
    m.TALLY_DIR = pathlib.Path(tally_tmp)
    m.tally_record({"tool_name": "Bash", "tool_input": {"command": "x"},
                    "session_id": "../../pwned"})
    escaped = os.path.exists(os.path.join(tally_tmp, "..", "..", "pwned.json"))
    landed = [f for f in os.listdir(tally_tmp) if f.endswith(".json")]
    want("tally_record sanitizes hostile session_id (no dir escape)",
         not escaped and len(landed) == 1)
finally:
    m.TALLY_DIR = _TALLY

# stop_pet's pid verification is safety-critical: the pid file survives pet
# crashes/reboots, so a reused pid whose argv merely LOOKS like the pet (an
# editor open on the sources) must not be SIGTERMed; only an exact command
# match is our pet; an unverifiable pid (ps failed) is left strictly alone.
killed = []
_pidcmd, _oskill, _pidfile = m.pet_pid_command, os.kill, m.PET_PID_FILE
life_tmp = tempfile.mkdtemp()
life_cfg = copy.deepcopy(cfg)
life_cfg["pet"]["state_dir"] = life_tmp
try:
    m.PET_PID_FILE = pathlib.Path(life_tmp) / "pet.pid"
    os.kill = lambda pid, sig: killed.append(pid)
    # (a) reused pid, substring look-alike -> no kill, pid file cleared
    m.PET_PID_FILE.write_text("4242")
    m.pet_pid_command = lambda pid: "/usr/bin/vim bin/noti-toast.swift pet-notes.md"
    m.stop_pet(life_cfg, quiet=True)
    want("stop_pet spares a reused pid that only looks like the pet",
         killed == [] and not m.PET_PID_FILE.exists())
    # (b) exact match -> our pet -> SIGTERM sent, pid file cleared
    m.PET_PID_FILE.write_text("4242")
    m.pet_pid_command = lambda pid: f"{m.BINARY} pet"
    m.stop_pet(life_cfg, quiet=True)
    want("stop_pet kills the verified pet",
         killed == [4242] and not m.PET_PID_FILE.exists())
    # (c) ps unverifiable -> leave the process AND pid file, return 1
    killed.clear()
    m.PET_PID_FILE.write_text("4242")
    m.pet_pid_command = lambda pid: None
    rc = m.stop_pet(life_cfg, quiet=True)
    want("stop_pet leaves an unverifiable pid untouched",
         killed == [] and rc == 1 and m.PET_PID_FILE.exists())
finally:
    m.pet_pid_command, os.kill, m.PET_PID_FILE = _pidcmd, _oskill, _pidfile

# cmd_pet refuses a duplicate launch (one critter, one question) rather than
# orphaning the first pet by clobbering its pid file.
_isrun, _launch, _lc2 = m.pet_is_running, m.launch_pet, m.load_config
launched = []
try:
    enabled_cfg = copy.deepcopy(cfg)
    enabled_cfg["pet"]["enabled"] = True
    m.load_config = lambda: enabled_cfg
    m.launch_pet = lambda c: (launched.append(1), 4321)[1]
    m.pet_is_running = lambda: 9999
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = m.cmd_pet(type("A", (), {"stop": False})())
    want("cmd_pet refuses a second launch when one is running",
         rc == 0 and not launched and "already running" in out.getvalue())
    m.pet_is_running = lambda: None
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = m.cmd_pet(type("A", (), {"stop": False})())
    want("cmd_pet launches when no pet is running",
         rc == 0 and launched == [1] and "started" in out.getvalue())
finally:
    m.pet_is_running, m.launch_pet, m.load_config = _isrun, _launch, _lc2

# launch_pet passes the pid-file path to the Swift pet so a UI-initiated close
# can tidy the same pid file that --stop/uninstall consult.
_pf, _bin, _popen, _sleep = m.PET_PID_FILE, m.BINARY, m.subprocess.Popen, m.time.sleep
env_tmp = tempfile.mkdtemp()
captured = {}
class _FakePetProc:
    pid = 7777
    returncode = None
    def poll(self):
        return None
def _fake_popen(argv, **kw):
    captured["argv"] = argv
    captured["env"] = kw.get("env")
    return _FakePetProc()
try:
    m.PET_PID_FILE = pathlib.Path(env_tmp) / "pet.pid"
    m.BINARY = pathlib.Path("/usr/bin/true")
    m.subprocess.Popen = _fake_popen
    m.time.sleep = lambda _secs: None
    lp_cfg = copy.deepcopy(cfg)
    lp_cfg["pet"]["state_dir"] = env_tmp
    pid = m.launch_pet(lp_cfg)
    want("launch_pet exports NOTI_PET_PID_FILE for UI close cleanup",
         pid == 7777 and captured.get("argv") == [str(m.BINARY), "pet"]
         and captured.get("env", {}).get("NOTI_PET_PID_FILE") == str(m.PET_PID_FILE)
         and m.PET_PID_FILE.read_text() == "7777")

    # The standing summons stands for pet.waiting_ttl_seconds, but never less
    # than ask_timeout+30 — a summons expiring under a still-live toast would
    # retract the card out from under the prompt it announces.
    lp_cfg["pet"]["waiting_ttl_seconds"] = 3600
    m.launch_pet(lp_cfg)
    want("launch_pet exports configured waiting TTL",
         captured.get("env", {}).get("NOTI_PET_WAITING_TTL") == "3600")
    lp_cfg["pet"]["waiting_ttl_seconds"] = 5      # below the toast's lifetime
    lp_cfg["toast"]["ask_timeout_seconds"] = 90
    m.launch_pet(lp_cfg)
    want("launch_pet clamps waiting TTL to ask_timeout+30",
         captured.get("env", {}).get("NOTI_PET_WAITING_TTL") == "120")
finally:
    m.PET_PID_FILE, m.BINARY = _pf, _bin
    m.subprocess.Popen, m.time.sleep = _popen, _sleep

# launch_pet confirms the process survived: an instant-exit binary (e.g. one
# predating pet mode) is a clean error, not a false "started (pid N)", and
# leaves no dead pid behind for --stop to trip over.
_pf, _bin = m.PET_PID_FILE, m.BINARY
lp_tmp = tempfile.mkdtemp()
try:
    m.PET_PID_FILE = pathlib.Path(lp_tmp) / "pet.pid"
    m.BINARY = pathlib.Path("/usr/bin/true")   # exists, ignores args, exits 0
    lp_cfg = copy.deepcopy(cfg)
    lp_cfg["pet"]["state_dir"] = lp_tmp
    raised = False
    try:
        m.launch_pet(lp_cfg)
    except RuntimeError:
        raised = True
    want("launch_pet errors on an instantly-dying binary, leaves no dead pid",
         raised and not m.PET_PID_FILE.exists())
finally:
    m.PET_PID_FILE, m.BINARY = _pf, _bin

sys.exit(1 if bad else 0)
PY
sec=$?

echo
echo "wire drift tripwire (free-text Other: exit code pinned in BOTH languages)"
# RC_OTHER=10 is hardcoded at the Swift submit site and named in Python; if
# either side drifts (renamed, revalued, or the submit site vanishes), the
# sentinel silently stops round-tripping — fail loudly instead.
wire=0
if grep -qE 'dismissThenExit\(code: 10,' bin/noti-toast.swift && grep -qE 'RC_OTHER = 10' noti; then
  echo "  ok   Swift dismissThenExit(code: 10, ...) <-> Python RC_OTHER = 10"
else
  echo "  FAIL RC_OTHER drift — Swift 'dismissThenExit(code: 10, ...)' and Python 'RC_OTHER = 10' must BOTH exist"
  wire=1
fi

echo
echo "summary: $pass passed, $fail failed (round-trip $([ $rt -eq 0 ] && echo ok || echo FAIL); security $([ $sec -eq 0 ] && echo ok || echo FAIL); wire $([ $wire -eq 0 ] && echo ok || echo FAIL))"
[ $fail -eq 0 ] && [ $rt -eq 0 ] && [ $sec -eq 0 ] && [ $wire -eq 0 ]
