#!/usr/bin/env bash
# Policy smoke tests — exercise `noti decide` (never shows a toast).
set -uo pipefail
cd "$(dirname "$0")"

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

CWD=$(pwd)
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
check "multi-question notifies"     "$(j AskUserQuestion '{"questions":[{"question":"Q1","options":[{"label":"A"},{"label":"B"}]},{"question":"Q2","options":[{"label":"C"},{"label":"D"}]}]}' default)" notice
check "4-option question notifies"  "$(j AskUserQuestion '{"questions":[{"question":"Q","options":[{"label":"A"},{"label":"B"},{"label":"C"},{"label":"D"}]}]}' default)" notice
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
echo "security regressions (the 8 review findings must stay fixed)"
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
     d4.get("question") == q["questions"][0]["question"]
     and d4.get("options") == ["JWT with long refresh tokens", "Server-side sessions"])
offcfg = copy.deepcopy(cfg); offcfg["approval"]["surface_plans"] = False
d5 = m.evaluate({"tool_name": "ExitPlanMode", "tool_input": {"plan": "x"},
                 "permission_mode": "plan", "cwd": sys.argv[1]}, offcfg)
want("surface_plans=false defers", d5["action"] == "defer")

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

sys.exit(1 if bad else 0)
PY
sec=$?

echo
echo "summary: $pass passed, $fail failed (round-trip $([ $rt -eq 0 ] && echo ok || echo FAIL); security $([ $sec -eq 0 ] && echo ok || echo FAIL))"
[ $fail -eq 0 ] && [ $rt -eq 0 ] && [ $sec -eq 0 ]
