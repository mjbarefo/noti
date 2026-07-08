---
name: preview-toasts
description: Render noti's toast cards to PNGs and review them visually. Use after any change to bin/noti-toast.swift, or when iterating on toast design, spacing, colors, or layout.
---

Render the toast UI to images and inspect them. Live screenshots don't work
(macOS strips windows without Screen Recording permission), so use the binary's
self-snapshot hook instead.

1. Rebuild first: `./noti build`
2. Snapshot representative cards to the scratchpad directory (each command
   writes the PNG ~0.5s after launch and exits on its own):

```bash
NOTI_SNAPSHOT="$DIR/ask-run.png" NOTI_TIMEOUT=30 NOTI_KIND=run NOTI_PROJECT=noti \
  ./bin/noti-toast ask "Run command" 'npm run build && ./test.sh --coverage' Yes Always No

NOTI_SNAPSHOT="$DIR/ask-edit.png" NOTI_TIMEOUT=30 NOTI_KIND=edit NOTI_PROJECT=my-webapp \
  ./bin/noti-toast ask "Edit file" '~/Documents/local-code/my-webapp/src/index.ts' Yes Always No

NOTI_SNAPSHOT="$DIR/summary.png" NOTI_TIMEOUT=30 NOTI_KIND=note \
  NOTI_FOOTER='ran 3 commands · edited 2 files' \
  ./bin/noti-toast summary "noti" "Fixed the bug and all tests pass."
```

3. Read each PNG and critique: dynamic height fitting the content, keycap chips
   legible, icon chip tint/glyph matching the kind, nothing truncated or
   overlapping, mono payload at full contrast. Add `NOTI_APPEARANCE=light` (or
   `dark`) to any command to force a palette — review both modes.
4. Also snapshot an edge case relevant to the change (long wrapped command,
   custom button labels via a plain `./bin/noti-toast ask` with no NOTI_KIND,
   empty body summary).

## Pet mood matrix

For any change touching the pet (drawRobot, PetView, PetDriver, attach mode),
walk one pet process through every mood and capture each pose.
`NOTI_PET_SNAPSHOT_DIR` writes a PNG after each state change settles;
`NOTI_PET_REDUCE_MOTION=1` forces the static branch so the halo discs are
drawn into the capture (cacheDisplay cannot see the live CALayer breath) and
the unfurl becomes a deterministic jump cut:

```bash
D="$DIR/pet-matrix"; S="$DIR/pet-state"; rm -rf "$D" "$S"; mkdir -p "$D" "$S"
NOTI_PET_STATE_DIR="$S" NOTI_PET_SNAPSHOT_DIR="$D" NOTI_PET_REDUCE_MOTION=1 \
  ./bin/noti-toast pet & PET=$!
sleep 1                                                              # 01 asleep
echo '{"state":"running","project":"noti"}' > "$S/a.json"; sleep 1   # 02 running
echo '{"state":"done","project":"noti"}'    > "$S/a.json"; sleep 1   # 03 done
echo '{"state":"failed","project":"noti"}'  > "$S/a.json"; sleep 1   # 04 failed + card
echo '{"state":"waiting","project":"noti"}' > "$S/a.json"; sleep 1   # 05 waiting + card
echo '{"state":"waiting","project":"web"}'  > "$S/b.json"; sleep 1   # 06 "2 sessions"
touch -A -0330 "$S/a.json"; sleep 1.5        # 07 "2 sessions · 3m" (oldest wait;
kill $PET                                    #    picked up by the 0.5s poll, not kqueue)
```

Read each PNG and critique: beacon color matches the mood (teal running,
green done, yellow waiting/failed), halo discs present on the breathing moods
(running/waiting/failed), the summons card wears the robot at the text-facing
edge with that arm raised and eyes glancing toward the text, asleep keeps its
static "z", caption names the project (or "N sessions"), nothing clipped. The
panel spawns at the persisted pet position, so which side the card unfurls to
follows wherever the real pet last sat.

Caveat: the vibrancy blur can't be captured this way — the background renders
flat. Judge layout, type, and color; judge translucency by launching a real
toast (`./noti notify ...`) and looking at the screen. Same for the pet's
live motion — beacon breath, blinks, sleep-z float, the done-bounce /
failed-shake reactions, and the unfurl: judge those by running the matrix
WITHOUT `NOTI_PET_REDUCE_MOTION` and watching the panel.
