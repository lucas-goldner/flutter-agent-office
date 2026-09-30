#!/usr/bin/env bash
# Starts the office from this checkout with workers that never stop to ask for permission and show
# up as Claude Code Remote Control sessions (watch and steer them from the Claude app on your phone).
#
#   ./run_agent_office.sh                     the office, in your browser (builds it first if needed)
#   ./run_agent_office.sh --mac               the server in the background and the Mac app in front;
#                                             quitting the app stops the server (workers keep running)
#   ./run_agent_office.sh --rebuild           rebuild first (after a git pull)
#   ./run_agent_office.sh ~/code/my-project   any other agent-office options are passed on
#
# --dangerously-skip-permissions lets every Claude worker run any command your user can without
# asking: use it on repositories you trust. Remote Control needs Claude Code signed in with your
# claude.ai account (run `claude`, then /login).
set -euo pipefail

cd "$(dirname "$0")"
bin=./dist/agent-office/agent-office
agent_args="--dangerously-skip-permissions --remote-control --remote-control-session-name-prefix office"

mac=false
rebuild=false
port=${PORT:-4600}
pass=()
while (($#)); do
  case "$1" in
    --rebuild) rebuild=true ;;
    --mac) mac=true ;;
    --port | -p)
      port="${2:?--port needs a number}"
      pass+=("$1" "$2")
      shift
      ;;
    *) pass+=("$1") ;;
  esac
  shift
done

if $rebuild; then
  dart tool/build.dart
elif [[ ! -x "$bin" ]]; then
  echo "agent-office isn't built yet: building it (a few minutes the first time)…"
  dart tool/build.dart
fi

$mac || exec "$bin" --agent-args "$agent_args" ${pass[@]+"${pass[@]}"}

# --mac: the server in the background, logging to dist/server.log, and the Mac app in front.
log=./dist/server.log
"$bin" --agent-args "$agent_args" --no-open ${pass[@]+"${pass[@]}"} >"$log" 2>&1 &
server=$!
# SIGTERM is the server's "restart": it stops, and the workers' terminals keep running for next time.
stop_server() { kill -TERM "$server" 2>/dev/null && wait "$server" 2>/dev/null || true; }
trap stop_server EXIT

echo "Starting the office server (log: $log)…"
for _ in $(seq 1 60); do
  if curl -fs -o /dev/null "http://127.0.0.1:$port/api/login"; then break; fi
  if ! kill -0 "$server" 2>/dev/null; then
    echo "The server stopped while starting:" >&2
    cat "$log" >&2
    exit 1
  fi
  sleep 1
done
grep -E "password|http://" "$log" | head -4 || true
echo "Sign in to http://localhost:$port in the app (it remembers you after that)."

cd app
flutter run -d macos
