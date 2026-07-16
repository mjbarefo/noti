<task>
Run a feasibility spike for click-to-focus in the `noti` repo at
/Users/jacobbarefoot/Documents/local-code/noti (macOS, Intel, Darwin 24.6).

Context: `noti` replaces Claude Code's terminal permission prompt with macOS
toasts via hooks (PreToolUse/Stop/StopFailure). It has an opt-in floating
"pet"; when a session needs a human, the pet presents a standing card
("Claude needs you · <project> · 4m"). The open question — tracked in DEV.md
under "Spike questions" — is whether CLICKING that card can focus the right
terminal window/tab. Hook payloads carry only `cwd` and `session_id`, which
DEV.md notes is "ambiguous across tabs and unresolvable over ssh/tmux".

Read first: DEV.md ("The pet — a standing summons" section and the R1–R7
invariants), docs/spikes/spike-pet.swift (the house spike pattern: a
standalone script with a numbered hand-runnable checklist in its header
comment), and `pet_record()` in the `noti` Python file (what hooks can
capture at write time).

Angles to probe with real evidence on this machine, in order:
1. Hook-time identity capture: when a Claude Code hook runs, does its process
   ancestry (ppid walk) reach the terminal emulator, and does any ancestor
   expose a TTY (`ps -o tty=`)? Simulate: run a probe script as a child of a
   shell in a real terminal and walk the chain. This decides whether noti
   could stamp terminal identity into the pet state file at `waiting` time.
2. TTY → window focus: can AppleScript select the Terminal.app tab whose
   `tty` matches (`every tab of every window whose tty is ...`), and the
   iTerm2 session equivalent if iTerm2 is installed? Verify focus actually
   moves: two windows open, script run from window A, target tab in window B.
3. Fallbacks when tty fails: window-title matching on the cwd basename via
   CGWindowListCopyWindowInfo or AX, and the floor — plain app activation.
4. Permission cost: record EXACTLY which consent dialogs appear (Automation
   per-app, Accessibility) and when. noti is zero-dependency: `osascript`
   and system frameworks are fine, package installs are not.
5. Degradation: what happens for ssh, tmux, and a VS Code embedded terminal
   if one is available — the answer "cleanly does nothing" is acceptable and
   must be verified, not assumed.

Deliverable: a new standalone spike at docs/spikes/spike-focus.sh (or .py /
.swift — pick one, zero-dep, self-contained) whose header carries a numbered
checklist a human can run to reproduce every claim, plus your verdict.
</task>

<action_safety>
This working copy is the user's LIVE hook install: their global Claude Code
settings execute `noti` from this directory in place. Do NOT modify `noti`,
`bin/noti-toast.swift`, `test.sh`, any config, or git state, and never run
`noti install`/`noti uninstall`. Create new files under docs/spikes/ only.
Kill every process and window your probes spawn before finishing.
</action_safety>

<grounding_rules>
This spike exists because the repo's rule is evidence before design. Ground
every claim in something you actually ran on this machine; label anything you
could not verify (e.g. iTerm2 absent, no ssh host available) as UNTESTED, not
as a conclusion. Do not present Apple documentation claims as observed
behavior.
</grounding_rules>

<research_mode>
Separate observed facts, inferences, and open questions. Breadth across the
five angles first; go deeper only where the result changes the verdict.
</research_mode>

<default_follow_through_policy>
Default to the most reasonable low-risk interpretation and keep going. The
one legitimate pause: if a macOS consent dialog (Automation/Accessibility)
needs a human click, stop and say exactly which dialog and for which app,
then continue after it is granted.
</default_follow_through_policy>

<verification_loop>
Before finalizing, re-run your own spike script's checklist top to bottom on
a clean shell and confirm each numbered item passes or is marked UNTESTED.
A checklist step that only worked mid-development does not count.
</verification_loop>

<structured_output_contract>
Return, in this order and nothing else:
1. VERDICT: one line — feasible / feasible-with-cost / infeasible — plus the
   cost (permission dialogs, terminal-app coverage).
2. EVIDENCE: one short block per angle (1–5): what you ran, what happened,
   fact vs inference. Include the exact ppid-walk finding and which
   AppleScript selector focused a tab, if any.
3. RECOMMENDED V1: at most 10 lines — what noti should capture at hook time,
   what the pet click should do, the degradation ladder, and a config
   kill-switch name (house style: R7 — observed-behavior features ship with
   one).
4. SPIKE FILE: path + one line on how to run its checklist.
</structured_output_contract>
