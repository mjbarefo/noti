#!/bin/zsh -f
# spike-focus.sh - Spike: can a pet click focus the terminal that owns a wait?
#
# Run from the repo root:
#   chmod +x docs/spikes/spike-focus.sh
#
# Checklist (pass = claims are backed by this machine, not docs):
#   1. Run `docs/spikes/spike-focus.sh --ppid-probe` from a normal Terminal.app
#      tab. Confirm the process walk shows a real tty for the shell/script and
#      whether it reaches Terminal.app.
#   2. Run `docs/spikes/spike-focus.sh --terminal-focus`. It opens two temporary
#      Terminal windows: TARGET and DRIVER. DRIVER runs this script, captures its
#      ppid chain, focuses TARGET by tty, then the spike closes both windows.
#   3. In the step 2 output, require `front_tty` to equal the target tty after
#      `window_tab_selector`. Record whether `every tab of w whose tty is ...`
#      worked or the loop fallback had to do the match.
#   4. In the step 2 fallback output, record whether CGWindowList exposed the
#      marker title and whether Terminal title matching could focus TARGET.
#   5. Run `docs/spikes/spike-focus.sh --iterm2`. If iTerm2 is not installed or
#      not running, mark the iTerm2 session selector UNTESTED.
#   6. Run `docs/spikes/spike-focus.sh --degradation`. Record tmux / ssh /
#      VS Code as observed or UNTESTED; do not infer behavior from absence.
#   7. Run `docs/spikes/spike-focus.sh --auto` from a clean shell before
#      finalizing. It performs steps 2, 5, and 6 and prints all evidence.
#   8. After any failed run, clean up windows titled NOTI_FOCUS_SPIKE_* and temp
#      files under `${TMPDIR:-/tmp}/noti-focus-spike-*`.
#
# This spike is intentionally zero-dependency: zsh, ps, osascript, swift, ssh,
# and tmux are system or user-provided tools. It does not read or write noti's
# real config, hook settings, state dir, Swift toast binary, or git state.

emulate -R zsh
set +x
unsetopt xtrace verbose 2>/dev/null || true
setopt typeset_silent
set -u

SCRIPT_PATH="${0:A}"
TMP_PARENT="${TMPDIR:-/tmp}"

usage() {
  cat <<'USAGE'
usage: docs/spikes/spike-focus.sh MODE

Modes:
  --ppid-probe       Print this process's ppid/tty ancestry.
  --terminal-focus   Open two Terminal windows and prove tty-to-tab focus.
  --iterm2           Probe whether iTerm2 is installed/running and exposes ttys.
  --degradation      Probe tmux, localhost ssh, and VS Code availability.
  --auto             Run terminal focus, iTerm2, and degradation probes.
  --focus-driver     Internal mode used by --terminal-focus.
USAGE
}

normalize_tty() {
  local tty_value="${1:-}"
  tty_value="${tty_value#/dev/}"
  if [[ "$tty_value" == "??" || "$tty_value" == "not a tty" ]]; then
    print -r -- ""
  else
    print -r -- "$tty_value"
  fi
}

timestamp_utc() {
  date -u "+%Y-%m-%dT%H:%M:%SZ"
}

ppid_walk() {
  local pid="${1:-$$}"
  local count=0

  print -r -- "PPID_WALK_COLUMNS=pid ppid tty comm"
  while [[ "$pid" == <-> && "$pid" -gt 0 && "$count" -lt 40 ]]; do
    local line
    line="$(ps -p "$pid" -o pid= -o ppid= -o tty= -o comm= 2>/dev/null || true)"
    if [[ -z "$line" ]]; then
      print -r -- "PPID_WALK_MISSING pid=$pid"
      break
    fi
    print -r -- "$line"

    local next_pid
    next_pid="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -z "$next_pid" || "$next_pid" == "$pid" ]]; then
      break
    fi
    pid="$next_pid"
    count=$((count + 1))
  done
}

probe_ppid() {
  local raw_tty
  raw_tty="$(tty 2>&1 || true)"
  print -r -- "PROBE_STARTED_AT=$(timestamp_utc)"
  print -r -- "CURRENT_TTY=$raw_tty"
  print -r -- "CURRENT_TTY_NORMALIZED=$(normalize_tty "$raw_tty")"
  ppid_walk "$$"
}

terminal_front_state() {
  /usr/bin/osascript <<'APPLESCRIPT'
on shortTTY(t)
  set s to t as text
  if s starts with "/dev/" then
    if (count of characters of s) > 5 then return text 6 thru -1 of s
  end if
  return s
end shortTTY

tell application "Terminal"
  if (count of windows) is 0 then return "TERMINAL_FRONT=none"
  set frontTTY to my shortTTY(tty of selected tab of front window)
  set frontName to name of front window as text
  set frontId to id of front window as text
  return "front_window_id=" & frontId & linefeed & "front_tty=" & frontTTY & linefeed & "front_name=" & frontName
end tell
APPLESCRIPT
}

terminal_focus_tty() {
  local target_tty
  target_tty="$(normalize_tty "${1:-}")"
  NOTI_FOCUS_TARGET_TTY="$target_tty" /usr/bin/osascript <<'APPLESCRIPT'
on shortTTY(t)
  set s to t as text
  if s starts with "/dev/" then
    if (count of characters of s) > 5 then return text 6 thru -1 of s
  end if
  return s
end shortTTY

set targetShort to system attribute "NOTI_FOCUS_TARGET_TTY"
set targetFull to "/dev/" & targetShort
set selectorReport to "window_tab_selector=no_match"

tell application "Terminal"
  try
    repeat with w in windows
      set matches to every tab of w whose tty is targetFull
      if (count of matches) > 0 then
        set t to item 1 of matches
        set selected tab of w to t
        set index of w to 1
        activate
        delay 0.3
        set frontTTY to my shortTTY(tty of selected tab of front window)
        set frontName to name of front window as text
        return "window_tab_selector=matched tty=" & targetShort & " front_tty=" & frontTTY & " front_name=" & frontName
      end if
    end repeat
  on error errMsg number errNo
    set selectorReport to "window_tab_selector_error=" & errNo & " " & errMsg
  end try

  repeat with w in windows
    repeat with t in tabs of w
      try
        set tabTTY to my shortTTY(tty of t)
      on error
        set tabTTY to ""
      end try
      if tabTTY is targetShort then
        set selected tab of w to t
        set index of w to 1
        activate
        delay 0.3
        set frontTTY to my shortTTY(tty of selected tab of front window)
        set frontName to name of front window as text
        return selectorReport & linefeed & "loop_selector=matched tty=" & tabTTY & " front_tty=" & frontTTY & " front_name=" & frontName
      end if
    end repeat
  end repeat
  activate
end tell

return selectorReport & linefeed & "loop_selector=no_match"
APPLESCRIPT
}

terminal_focus_window_id() {
  local window_id="${1:-}"
  NOTI_FOCUS_WINDOW_ID="$window_id" /usr/bin/osascript <<'APPLESCRIPT'
set targetId to (system attribute "NOTI_FOCUS_WINDOW_ID") as integer
tell application "Terminal"
  set index of (first window whose id is targetId) to 1
  activate
  delay 0.2
  return "window_id_selector=matched " & (id of front window as text)
end tell
APPLESCRIPT
}

terminal_focus_title() {
  local title_marker="${1:-}"
  NOTI_FOCUS_TITLE="$title_marker" /usr/bin/osascript <<'APPLESCRIPT'
set titleMarker to system attribute "NOTI_FOCUS_TITLE"
tell application "Terminal"
  repeat with w in windows
    try
      set windowName to name of w as text
    on error
      set windowName to ""
    end try
    if windowName contains titleMarker then
      set index of w to 1
      activate
      delay 0.2
      return "title_selector=matched front_name=" & (name of front window as text)
    end if
  end repeat
end tell
return "title_selector=no_match"
APPLESCRIPT
}

setup_terminal_windows() {
  local result_file="$1"
  local done_file="$2"
  local marker="$3"

  NOTI_FOCUS_SCRIPT="$SCRIPT_PATH" \
  NOTI_FOCUS_RESULT="$result_file" \
  NOTI_FOCUS_DONE="$done_file" \
  NOTI_FOCUS_MARKER="$marker" \
  /usr/bin/osascript <<'APPLESCRIPT'
on shortTTY(t)
  set s to t as text
  if s starts with "/dev/" then
    if (count of characters of s) > 5 then return text 6 thru -1 of s
  end if
  return s
end shortTTY

set scriptPath to system attribute "NOTI_FOCUS_SCRIPT"
set resultFile to system attribute "NOTI_FOCUS_RESULT"
set doneFile to system attribute "NOTI_FOCUS_DONE"
set marker to system attribute "NOTI_FOCUS_MARKER"

tell application "Terminal"
  activate

  set targetCommand to "printf '\\e]0;" & marker & "_TARGET\\a'; echo " & quoted form of (marker & " TARGET") & "; tty; while [ ! -f " & quoted form of doneFile & " ]; do sleep 0.2; done; exit"
  do script targetCommand
  delay 0.5
  set targetWindowId to id of front window

  set targetTTY to ""
  repeat 40 times
    try
      set targetTTY to tty of selected tab of front window as text
      if targetTTY is not "" then exit repeat
    end try
    delay 0.2
  end repeat
  set targetShort to my shortTTY(targetTTY)

  set driverCommand to "printf '\\e]0;" & marker & "_DRIVER\\a'; " & quoted form of scriptPath & " --focus-driver " & quoted form of targetShort & " " & quoted form of resultFile & " " & quoted form of marker & "; while [ ! -f " & quoted form of doneFile & " ]; do sleep 0.2; done; exit"
  do script driverCommand
  delay 0.5
  set driverWindowId to id of front window

  return "target_window_id=" & (targetWindowId as text) & linefeed & "driver_window_id=" & (driverWindowId as text) & linefeed & "target_tty=" & targetTTY & linefeed & "target_tty_short=" & targetShort
end tell
APPLESCRIPT
}

cleanup_terminal_windows() {
  local done_file="$1"
  shift
  local ids=("$@")

  touch "$done_file" 2>/dev/null || true
  sleep 1

  NOTI_FOCUS_WINDOW_IDS="${(j: :)ids}" /usr/bin/osascript <<'APPLESCRIPT' 2>/dev/null || true
set idsText to system attribute "NOTI_FOCUS_WINDOW_IDS"
set idWords to words of idsText
tell application "Terminal"
  repeat with rawId in idWords
    try
      set targetId to rawId as integer
      close (first window whose id is targetId)
    end try
  end repeat
end tell
APPLESCRIPT
}

focus_driver() {
  local target_tty="${1:-}"
  local result_file="${2:-}"
  local marker="${3:-}"
  local tmp_file="${result_file}.tmp"

  {
    print -r -- "DRIVER_STARTED_AT=$(timestamp_utc)"
    print -r -- "DRIVER_MARKER=$marker"
    print -r -- "DRIVER_TTY=$(tty 2>&1 || true)"
    print -r -- "TARGET_TTY=$target_tty"
    print -r -- "PPID_WALK_BEGIN"
    ppid_walk "$$"
    print -r -- "PPID_WALK_END"
    print -r -- "TTY_FOCUS_BEGIN"
    terminal_focus_tty "$target_tty" 2>&1
    print -r -- "TTY_FOCUS_EXIT=$?"
    print -r -- "TTY_FOCUS_END"
    print -r -- "FRONT_AFTER_TTY_FOCUS_BEGIN"
    terminal_front_state 2>&1
    print -r -- "FRONT_AFTER_TTY_FOCUS_END"
  } > "$tmp_file"
  mv "$tmp_file" "$result_file"
}

cgwindow_probe() {
  local marker="$1"
  NOTI_FOCUS_MARKER="$marker" /usr/bin/swift - <<'SWIFT'
import CoreGraphics
import Foundation

let marker = ProcessInfo.processInfo.environment["NOTI_FOCUS_MARKER"] ?? ""
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let rows = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [[String: Any]] ?? []
var markerHits = 0
var terminalRows = 0

for row in rows {
    let owner = row[kCGWindowOwnerName as String] as? String ?? ""
    let name = row[kCGWindowName as String] as? String ?? ""
    let pid = row[kCGWindowOwnerPID as String] as? Int ?? 0
    if owner == "Terminal" || name.contains(marker) {
        terminalRows += 1
        print("CGWINDOW owner=\(owner) pid=\(pid) name=\(name)")
    }
    if name.contains(marker) {
        markerHits += 1
    }
}

print("CGWINDOW_TERMINAL_ROWS=\(terminalRows)")
print("CGWINDOW_MARKER_HITS=\(markerHits)")
SWIFT
}

run_terminal_focus_probe() {
  local marker="NOTI_FOCUS_SPIKE_$(date +%s)_$$"
  local tmp_dir="${TMP_PARENT}/noti-focus-spike-${marker}"
  local result_file="${tmp_dir}/driver-result.txt"
  local done_file="${tmp_dir}/done"
  mkdir -p "$tmp_dir"

  print -r -- "TERMINAL_FOCUS_PROBE marker=$marker"
  print -r -- "TERMINAL_FOCUS_TEMP=$tmp_dir"

  local setup_out
  setup_out="$(setup_terminal_windows "$result_file" "$done_file" "$marker" 2>&1)"
  local setup_rc=$?
  print -r -- "TERMINAL_SETUP_BEGIN"
  print -r -- "$setup_out"
  print -r -- "TERMINAL_SETUP_EXIT=$setup_rc"
  print -r -- "TERMINAL_SETUP_END"

  local target_window_id driver_window_id target_tty_short
  target_window_id="$(print -r -- "$setup_out" | awk -F= '/^target_window_id=/{print $2; exit}')"
  driver_window_id="$(print -r -- "$setup_out" | awk -F= '/^driver_window_id=/{print $2; exit}')"
  target_tty_short="$(print -r -- "$setup_out" | awk -F= '/^target_tty_short=/{print $2; exit}')"

  if [[ "$setup_rc" -ne 0 || -z "$target_window_id" || -z "$driver_window_id" ]]; then
    print -r -- "TERMINAL_FOCUS_RESULT=UNTESTED setup_failed"
    cleanup_terminal_windows "$done_file" "$target_window_id" "$driver_window_id"
    return 1
  fi

  local waited=0
  while [[ ! -f "$result_file" && "$waited" -lt 80 ]]; do
    sleep 0.25
    waited=$((waited + 1))
  done

  print -r -- "DRIVER_RESULT_BEGIN"
  if [[ -f "$result_file" ]]; then
    cat "$result_file"
  else
    print -r -- "DRIVER_RESULT_MISSING waited=$waited"
  fi
  print -r -- "DRIVER_RESULT_END"

  print -r -- "FALLBACK_CGWINDOW_BEGIN"
  cgwindow_probe "$marker" 2>&1
  print -r -- "FALLBACK_CGWINDOW_END"

  print -r -- "FALLBACK_TITLE_BEGIN"
  terminal_focus_window_id "$driver_window_id" 2>&1
  terminal_focus_title "${marker}_TARGET" 2>&1
  terminal_front_state 2>&1
  print -r -- "FALLBACK_TITLE_END"

  if [[ -n "$target_tty_short" ]]; then
    print -r -- "TERMINAL_FOCUS_EXPECTED_TARGET_TTY=$target_tty_short"
  fi

  cleanup_terminal_windows "$done_file" "$target_window_id" "$driver_window_id"
}

probe_iterm2() {
  print -r -- "ITERM2_PROBE_BEGIN"

  local app_name=""
  local bundle_id=""
  local probe
  for probe in "iTerm2" "iTerm"; do
    local id_out
    id_out="$(/usr/bin/osascript -e "id of application \"$probe\"" 2>&1)"
    if [[ "$?" -eq 0 ]]; then
      app_name="$probe"
      bundle_id="$id_out"
      break
    fi
  done

  if [[ -z "$app_name" ]]; then
    print -r -- "ITERM2_STATUS=UNTESTED not_installed_or_not_resolvable"
    print -r -- "ITERM2_PROBE_END"
    return 0
  fi

  print -r -- "ITERM2_APP_NAME=$app_name"
  print -r -- "ITERM2_BUNDLE_ID=$bundle_id"

  local running
  running="$(/usr/bin/osascript -e "application \"$app_name\" is running" 2>&1 || true)"
  print -r -- "ITERM2_RUNNING=$running"
  if [[ "$running" != "true" ]]; then
    print -r -- "ITERM2_SESSION_SELECTOR=UNTESTED app_not_running"
    print -r -- "ITERM2_PROBE_END"
    return 0
  fi

  NOTI_FOCUS_ITERM_APP="$app_name" /usr/bin/osascript <<'APPLESCRIPT' 2>&1
set appName to system attribute "NOTI_FOCUS_ITERM_APP"
set rows to {}
try
  tell application appName
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          try
            set end of rows to "iterm2_session_tty=" & (tty of s as text)
          on error errMsg number errNo
            set end of rows to "iterm2_session_tty_error=" & errNo & " " & errMsg
          end try
        end repeat
      end repeat
    end repeat
  end tell
on error errMsg number errNo
  return "ITERM2_SESSION_SELECTOR=UNTESTED apple_event_error=" & errNo & " " & errMsg
end try

if (count of rows) is 0 then return "ITERM2_SESSION_SELECTOR=UNTESTED no_open_sessions"
set AppleScript's text item delimiters to linefeed
return rows as text
APPLESCRIPT
  print -r -- "ITERM2_PROBE_END"
}

probe_degradation() {
  print -r -- "DEGRADATION_PROBE_BEGIN"

  if command -v tmux >/dev/null 2>&1; then
    local marker="noti-focus-tmux-$$"
    local out_file="${TMP_PARENT}/noti-focus-tmux-${marker}.txt"
    print -r -- "TMUX_STATUS=installed"
    tmux new-session -d -s "$marker" "$SCRIPT_PATH --ppid-probe > '$out_file' 2>&1; sleep 1" 2>/dev/null
    local tmux_rc=$?
    sleep 2
    print -r -- "TMUX_NEW_SESSION_EXIT=$tmux_rc"
    if [[ -f "$out_file" ]]; then
      print -r -- "TMUX_PPID_PROBE_BEGIN"
      cat "$out_file"
      print -r -- "TMUX_PPID_PROBE_END"
      rm -f "$out_file"
    else
      print -r -- "TMUX_PPID_PROBE=UNTESTED no_output"
    fi
    tmux kill-session -t "$marker" >/dev/null 2>&1 || true
  else
    print -r -- "TMUX_STATUS=UNTESTED tmux_not_installed"
  fi

  if command -v ssh >/dev/null 2>&1; then
    local ssh_out
    ssh_out="$(ssh -o BatchMode=yes -o ConnectTimeout=2 localhost 'tty; ps -p $$ -o pid= -o ppid= -o tty= -o comm=' 2>&1)"
    local ssh_rc=$?
    print -r -- "SSH_LOCALHOST_EXIT=$ssh_rc"
    if [[ "$ssh_rc" -eq 0 ]]; then
      print -r -- "SSH_LOCALHOST_PROBE_BEGIN"
      print -r -- "$ssh_out"
      print -r -- "SSH_LOCALHOST_PROBE_END"
    else
      print -r -- "SSH_STATUS=UNTESTED no_batchmode_localhost_ssh"
      print -r -- "SSH_ERROR=$ssh_out"
    fi
  else
    print -r -- "SSH_STATUS=UNTESTED ssh_client_not_installed"
  fi

  local vscode_app_available="false"
  if command -v code >/dev/null 2>&1; then
    vscode_app_available="true"
  fi
  if [[ -d "/Applications/Visual Studio Code.app" || -d "$HOME/Applications/Visual Studio Code.app" ]]; then
    vscode_app_available="true"
  fi
  if [[ "$vscode_app_available" == "true" ]]; then
    local code_running
    code_running="$(/usr/bin/osascript -e 'application "Visual Studio Code" is running' 2>&1 || true)"
    print -r -- "VSCODE_AVAILABLE=true"
    print -r -- "VSCODE_RUNNING=$code_running"
    print -r -- "VSCODE_EMBEDDED_TERMINAL=UNTESTED no_existing_terminal_probe_without_AX"
  else
    print -r -- "VSCODE_EMBEDDED_TERMINAL=UNTESTED code_app_or_cli_not_found"
  fi

  print -r -- "DEGRADATION_PROBE_END"
}

run_auto() {
  print -r -- "AUTO_PROBE_STARTED_AT=$(timestamp_utc)"
  print -r -- "AUTO_CURRENT_PROCESS_BEGIN"
  probe_ppid
  print -r -- "AUTO_CURRENT_PROCESS_END"
  run_terminal_focus_probe
  probe_iterm2
  probe_degradation
  print -r -- "AUTO_PROBE_FINISHED_AT=$(timestamp_utc)"
}

case "${1:-}" in
  --ppid-probe)
    probe_ppid
    ;;
  --terminal-focus)
    run_terminal_focus_probe
    ;;
  --iterm2)
    probe_iterm2
    ;;
  --degradation)
    probe_degradation
    ;;
  --auto)
    run_auto
    ;;
  --focus-driver)
    focus_driver "${2:-}" "${3:-}" "${4:-}"
    ;;
  *)
    usage
    exit 2
    ;;
esac
