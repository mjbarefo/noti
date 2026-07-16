#!/bin/zsh -f
# make-screenshots.sh — regenerate every README image from the current binary.
#
# Run from the repo root after `./noti build`:
#   docs/make-screenshots.sh
#
# Uses the binary's NOTI_SNAPSHOT self-render (and the pet's
# NOTI_PET_SNAPSHOT_DIR walk), so no Screen Recording permission is needed and
# the pixels are exactly what the shipped binary draws. Writes light+dark for
# each card into docs/. The README embeds them via <picture> so GitHub serves
# the palette matching the viewer's theme.
set -e
cd "$(dirname "$0")/.."
BIN=./bin/noti-toast
[[ -x $BIN ]] || { echo "build first: ./noti build" >&2; exit 1; }

US=$'\x1f'   # NOTI_OPTIONS / NOTI_DESCS field separator (see _toast_env)

for mode in light dark; do
  export NOTI_APPEARANCE=$mode NOTI_TIMEOUT=30

  NOTI_SNAPSHOT=docs/approval-$mode.png NOTI_KIND=run NOTI_PROJECT=web-dashboard \
    $BIN ask "Run command" 'git push origin main --force' Yes Always No

  NOTI_SNAPSHOT=docs/question-$mode.png NOTI_KIND=question NOTI_PROJECT=noti \
    NOTI_OTHER=1 \
    NOTI_OPTIONS="Commits + v0.4.0 tag (Recommended)${US}Commits + both tags${US}Hold the tag for now" \
    NOTI_DESCS="Tag the release now so the README badge and install docs point at a fixed ref.${US}Tag v0.4.0 and v0.5.0 together once the changelog entries are split.${US}Keep shipping from main; tag later when the API settles." \
    $BIN ask "Claude asks — Release" "How should we handle the release tagging for v0.4.0?" \
    "Commits + v0.4.0 tag (Recommended)" "Commits + both tags" "Hold the tag for now"

  NOTI_SNAPSHOT=docs/plan-$mode.png NOTI_KIND=plan NOTI_PROJECT=api-server \
    $BIN ask "Plan ready for review" \
    'Add JWT auth: token-refresh middleware, a login route, and tests. 3 files, ~120 lines.' \
    Approve View

  NOTI_SNAPSHOT=docs/summary-$mode.png NOTI_FOOTER='ran 3 commands · edited 2 files' \
    $BIN summary "web-dashboard" "Added the dark-mode toggle and fixed the header overflow on mobile."

  NOTI_SNAPSHOT=docs/error-$mode.png NOTI_KIND=error \
    NOTI_FOOTER='after ran 3 commands · edited 1 file' \
    $BIN summary "web-dashboard" "Turn ended: rate limited"

  # The pet's standing summons: walk one throwaway pet (own state dir — the
  # live pet is untouched) into a waiting state aged a few minutes, and take
  # the settled capture. Reduce-motion forces the deterministic static branch.
  petdir=$(mktemp -d) snapdir=$(mktemp -d)
  NOTI_PET_STATE_DIR=$petdir NOTI_PET_SNAPSHOT_DIR=$snapdir NOTI_PET_REDUCE_MOTION=1 \
    $BIN pet & pet_pid=$!
  sleep 1
  echo '{"state":"waiting","project":"web-dashboard"}' > "$petdir/a.json"
  touch -A -0430 "$petdir/a.json"
  sleep 1.5
  kill $pet_pid
  cp "$snapdir"/*waiting*.png docs/summons-$mode.png
  rm -rf "$petdir" "$snapdir"
done
unset NOTI_APPEARANCE NOTI_TIMEOUT
ls -la docs/*.png
