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

Caveat: the vibrancy blur can't be captured this way — the background renders
flat. Judge layout, type, and color; judge translucency by launching a real
toast (`./noti notify ...`) and looking at the screen.
