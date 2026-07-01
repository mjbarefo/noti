#!/usr/bin/env bash
# Build the toast binary and wire up the Claude Code hooks.
#   ./install.sh            # install into ~/.claude (everywhere)
#   ./install.sh --project . # install into ./.claude (this project only)
set -euo pipefail
cd "$(dirname "$0")"

./noti build
./noti install "$@"
echo
echo "Done. Try it:  ./noti notify --title noti --body 'hello from noti'"
