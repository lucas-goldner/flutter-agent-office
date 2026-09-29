#!/usr/bin/env bash
# Starts the office from this checkout with workers that never stop to ask for permission and show
# up as Claude Code Remote Control sessions (watch and steer them from the Claude app on your phone).
#
#   ./run_agent_office.sh                     start it (builds it first if it hasn't been built yet)
#   ./run_agent_office.sh --rebuild           rebuild first (after a git pull)
#   ./run_agent_office.sh ~/code/my-project   any other agent-office options are passed on
#
# --dangerously-skip-permissions lets every Claude worker run any command your user can without
# asking: use it on repositories you trust. Remote Control needs Claude Code signed in with your
# claude.ai account (run `claude`, then /login).
set -euo pipefail

cd "$(dirname "$0")"
bin=./dist/agent-office/agent-office

if [[ "${1:-}" == "--rebuild" ]]; then
  shift
  dart tool/build.dart
elif [[ ! -x "$bin" ]]; then
  echo "agent-office isn't built yet: building it (a few minutes the first time)…"
  dart tool/build.dart
fi

exec "$bin" \
  --agent-args "--dangerously-skip-permissions --remote-control --remote-control-session-name-prefix office" \
  "$@"
