#!/usr/bin/env bash
# Starts the office from this checkout with workers that never stop to ask for permission and show
# up as Claude Code Remote Control sessions (watch and steer them from the Claude app on your phone).
#
#   ./run_agent_office.sh                     the office, in your browser (builds it first if needed)
#   ./run_agent_office.sh --mac               the server in the background and the Mac app in front;
#                                             quitting the app stops the server (workers keep running)
#   ./run_agent_office.sh --mac --release     the same with a release build of the Mac app (much faster
#                                             than flutter run's debug build): built when the code
#                                             changed, installed as /Applications/Agent Office.app
#                                             (replacing the one there) and opened from there
#   ./run_agent_office.sh --rebuild           rebuild first (after a git pull)
#   ./run_agent_office.sh ~/code/my-project   any other agent-office options are passed on
#
# Secrets (CODEMAGIC_TOKEN, …) come from .env next to this script: cp .env.example .env and fill it in.
#
# --dangerously-skip-permissions lets every Claude worker run any command your user can without
# asking: use it on repositories you trust. Remote Control needs Claude Code signed in with your
# claude.ai account (run `claude`, then /login).
set -euo pipefail

cd "$(dirname "$0")"
bin=./dist/agent-office/agent-office
agent_args="--dangerously-skip-permissions --remote-control --remote-control-session-name-prefix office"

# Secrets the office starts with (CODEMAGIC_TOKEN, …) from .env next to this script, if there is one.
# It's in .gitignore: copy .env.example to .env and fill it in. What's already set in your shell wins.
if [[ -f .env ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    line="${line#export }"
    key="${line%%=*}"
    value="${line#*=}"
    value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -n "${!key:-}" ]] || export "$key=$value"
  done < .env
fi

mac=false
release=false
rebuild=false
port=${PORT:-4600}
pass=()
while (($#)); do
  case "$1" in
    --rebuild) rebuild=true ;;
    --mac) mac=true ;;
    --release) release=true ;;
    --port | -p)
      port="${2:?--port needs a number}"
      pass+=("$1" "$2")
      shift
      ;;
    *) pass+=("$1") ;;
  esac
  shift
done

# Dart: on the PATH, or the one inside Flutter (Flutter ships its own: bin/dart next to bin/flutter),
# or FVM's.
dart_bin() {
  if command -v dart >/dev/null 2>&1; then echo dart; return; fi
  local f
  if f=$(command -v flutter 2>/dev/null); then
    # Follow symlinks (Homebrew, asdf, …) to Flutter's own bin folder.
    while [[ -L "$f" ]]; do
      local link; link=$(readlink "$f")
      [[ "$link" = /* ]] && f="$link" || f="$(dirname "$f")/$link"
    done
    if [[ -x "$(dirname "$f")/dart" ]]; then echo "$(dirname "$f")/dart"; return; fi
  fi
  if command -v fvm >/dev/null 2>&1; then echo "fvm dart"; return; fi
  echo "Can't find dart: install Flutter (https://docs.flutter.dev/get-started/install) and put its bin folder on your PATH" >&2
  exit 1
}
dart=$(dart_bin) || exit 1

if $rebuild; then
  $dart tool/build.dart
elif [[ ! -x "$bin" ]]; then
  echo "agent-office isn't built yet: building it (a few minutes the first time)…"
  $dart tool/build.dart
fi

if $release && ! $mac; then
  echo "--release is for the Mac app: ./run_agent_office.sh --mac --release" >&2
  exit 2
fi
$mac || exec "$bin" --agent-args "$agent_args" ${pass[@]+"${pass[@]}"}

# --mac --release: the Mac app, built for release when its code changed since the one installed (or
# with --rebuild), and put in /Applications in place of the old one.
installed="/Applications/Agent Office.app"
if $release; then
  stamp=./dist/mac-release.stamp
  # What the app is built from: the commit, plus any changes not committed yet.
  want="$(git rev-parse HEAD 2>/dev/null)-$(git status --porcelain -- app packages 2>/dev/null | shasum | cut -c1-12)"
  if $rebuild || [[ ! -d "$installed" ]] || [[ "$(cat "$stamp" 2>/dev/null)" != "$want" ]]; then
    echo "Building the Mac app for release (a few minutes)…"
    (cd app && flutter build macos --release)
    built="app/build/macos/Build/Products/Release/agent_office.app"
    [[ -d "$built" ]] || { echo "The release build isn't where it should be: $built" >&2; exit 1; }
    # Quit the one running from /Applications, if it is, before replacing it.
    pkill -f "$installed/Contents/MacOS/" 2>/dev/null && sleep 1 || true
    rm -rf "$installed"
    ditto "$built" "$installed"
    mkdir -p dist && echo "$want" >"$stamp"
    echo "Installed $installed"
  else
    echo "$installed is up to date (--rebuild builds it again anyway)."
  fi
fi

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

if $release; then
  # -W: until you quit it, so quitting the app stops the server, as with flutter run.
  open -W "$installed"
else
  cd app
  flutter run -d macos
fi
