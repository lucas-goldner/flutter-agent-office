#!/usr/bin/env bash
# Install the latest Agent Office release and start it, no clone needed:
#
#   curl -fsSL https://raw.githubusercontent.com/lucas-goldner/flutter-agent-office/main/install.sh | bash
#
# Anything after `bash -s --` goes to the office, e.g. a port:
#
#   curl -fsSL https://raw.githubusercontent.com/lucas-goldner/flutter-agent-office/main/install.sh | bash -s -- --port 4700
#
# The first time the office starts in a terminal it asks where to clone your projects, signs the
# GitHub CLI in if it isn't, and lets you pick your first repository to clone as a floor.
#
# A release is one executable plus the web client, built for Linux and macOS on x64 and arm64; no
# Node.js needed. Releases go in ~/.local/share/agent-office (versions/<tag>, with `current` linking
# to the one in use) and ~/.local/bin/agent-office links to it, so afterwards `agent-office` starts
# it too. Run the curl line again to update to the newest release.
#
# Environment:
#   AGENT_OFFICE_VERSION       install this release (a tag like v0.1.68) instead of the newest
#   AGENT_OFFICE_REPO          the GitHub repo to install releases of (default lucas-goldner/flutter-agent-office)
#   AGENT_OFFICE_INSTALL_DIR   where releases go (default ~/.local/share/agent-office)
#   AGENT_OFFICE_BIN_DIR       where the `agent-office` command goes (default ~/.local/bin; empty: none)
#   AGENT_OFFICE_INSTALL_ONLY  1: install, but don't start the office
#   AGENT_OFFICE_TARBALL       install this release tarball (a local file) instead of downloading one
#   AGENT_OFFICE_RELEASES_URL  download from here instead of https://github.com/<repo>/releases, laid
#                              out the same way: <url>/download/<tag>/<file> and
#                              <url>/latest/download/<file> (a mirror, or a file:// folder for tests)
set -euo pipefail

REPO="${AGENT_OFFICE_REPO:-lucas-goldner/flutter-agent-office}"
RELEASES="${AGENT_OFFICE_RELEASES_URL:-https://github.com/$REPO/releases}"
RELEASES="${RELEASES%/}"
MARKER="agent-office launcher, written by install.sh"
INSTALL_DIR="${AGENT_OFFICE_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-office}"
VERSIONS="$INSTALL_DIR/versions"
BIN_DIR="${AGENT_OFFICE_BIN_DIR-$HOME/.local/bin}"
STAGE=""
TAG=""
LAUNCHER=""
PLATFORM=""

if [ -t 2 ]; then BOLD=$'\033[1m' CYAN=$'\033[1;36m' YELLOW=$'\033[1;33m' RED=$'\033[1;31m' RESET=$'\033[0m'
else BOLD="" CYAN="" YELLOW="" RED="" RESET=""; fi
step() { printf '%s==>%s %s\n' "$CYAN" "$RESET" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() { printf '%sagent-office:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then rm -rf "$STAGE"; fi
}

# linux-x64, linux-arm64, darwin-x64 or darwin-arm64: which release tarball to get.
detect_platform() {
  local os arch
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) die "Agent Office runs on macOS and Linux. On Windows, run this inside WSL." ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=x64 ;;
    arm64 | aarch64) arch=arm64 ;;
    *) die "Agent Office is built for x64 and arm64 machines, and this one is $(uname -m)." ;;
  esac
  # A shell running under Rosetta says x86_64 on an Apple silicon Mac; get the native build.
  if [ "$os" = darwin ] && [ "$arch" = x64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then
    arch=arm64
  fi
  PLATFORM="$os-$arch"
}

check_requirements() {
  detect_platform
  have curl || die "this needs curl."
  have tar || die "this needs tar."
  have sha256sum || have shasum || die "this needs sha256sum or shasum, to check the download."
  have git || warn "git isn't installed. The office needs it for projects and worker worktrees."
  if ! have claude && ! have opencode && ! have codex; then
    warn "no Claude Code, OpenCode or Codex CLI found on your PATH. Workers need one of them, e.g."
    warn "  curl -fsSL https://claude.ai/install.sh | bash"
  fi
}

sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# The newest release's tag, from where github.com/<repo>/releases/latest redirects (no API rate limit).
latest_tag() {
  local url
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$RELEASES/latest" 2>/dev/null)" || return 0
  case "$url" in
    */releases/tag/*) printf '%s' "${url##*/releases/tag/}" ;;
  esac
}

valid_tag() {
  [[ "$1" =~ ^v[0-9][0-9A-Za-z._+-]*$ ]]
}

# The value of a `"key": "value",` line of an install.json.
json_field() {
  sed -n "s/^ *\"$2\": *\"\\([^\"]*\\)\".*/\\1/p" "$1" | head -n 1
}

installed() {
  [ -x "$VERSIONS/$1/agent-office" ] && [ -f "$VERSIONS/$1/.installed" ]
}

# Downloads (unless given one) and unpacks a release tarball into $VERSIONS/<tag>. A download is
# checked against the release's SHA256SUMS. Everything happens in a scratch directory first, so a
# failed or interrupted install never leaves a broken version behind. Without a tag it gets the
# newest release and reads the tag from the tarball. Sets TAG.
install_release() {
  local tag="$1" tarball="$2" asset="agent-office-$PLATFORM.tar.gz" from want got dest shipped built
  mkdir -p "$VERSIONS"
  STAGE="$(mktemp -d "$VERSIONS/.install.XXXXXX")"
  if [ -n "$tarball" ]; then
    cp "$tarball" "$STAGE/$asset"
  else
    if [ -n "$tag" ]; then from="$RELEASES/download/$tag"; else from="$RELEASES/latest/download"; fi
    step "Downloading Agent Office ${tag:-(newest release)} for $PLATFORM"
    curl -fSL --progress-bar -o "$STAGE/$asset" "$from/$asset" ||
      die "couldn't download $asset from release ${tag:-latest} (is that a release at $RELEASES ?)"
    curl -fsSL -o "$STAGE/SHA256SUMS" "$from/SHA256SUMS" || die "couldn't download the release's SHA256SUMS"
    want="$(awk -v f="$asset" '$2 == f || $2 == "*" f {print tolower($1)}' "$STAGE/SHA256SUMS" | head -n 1)"
    [ -n "$want" ] || die "the release's SHA256SUMS doesn't list $asset"
    got="$(sha256_of "$STAGE/$asset")"
    [ "$got" = "$want" ] || die "the download is corrupt (its sha256 is $got, the release says $want). Run this again."
  fi
  tar -xzf "$STAGE/$asset" -C "$STAGE" || die "that isn't a release tarball"
  [ -f "$STAGE/agent-office/agent-office" ] && [ -f "$STAGE/agent-office/web/index.html" ] ||
    die "that release tarball doesn't contain Agent Office"
  local info="$STAGE/agent-office/install.json"
  [ -f "$info" ] || die "that release tarball has no install.json"
  shipped="$(json_field "$info" tag)"
  if [ -z "$tag" ]; then tag="$shipped"; fi
  valid_tag "$tag" || die "not a release version: ${tag:-(none in the tarball)}"
  [ "$shipped" = "$tag" ] || warn "the tarball says it is ${shipped:-no version}, not $tag"
  built="$(json_field "$info" os)-$(json_field "$info" arch)"
  [ "$built" = "$PLATFORM" ] || die "that release tarball is built for $built, and this is $PLATFORM"
  chmod 755 "$STAGE/agent-office/agent-office"
  # Record where it came from, so the office's own upgrades follow the same repo. The rest (the
  # commit it was built from) stays as the release wrote it.
  sed -e "s#^\\( *\"repo\": *\"\\)[^\"]*\"#\\1$REPO\"#" -e "s#^\\( *\"tag\": *\"\\)[^\"]*\"#\\1$tag\"#" "$info" >"$STAGE/install.json"
  mv -f "$STAGE/install.json" "$info"
  dest="$VERSIONS/$tag"
  if ! installed "$tag"; then
    step "Installing Agent Office $tag"
    touch "$STAGE/agent-office/.installed"
    # A folder of the same name left by an older, Node.js release (no binary in it) is replaced.
    if [ -f "$dest/.installed" ] && [ ! -e "$dest/agent-office" ]; then rm -rf "$dest"; fi
    # Another run may have installed the same version meanwhile; either copy will do.
    if [ ! -e "$dest" ]; then mv "$STAGE/agent-office" "$dest"
    elif ! installed "$tag"; then die "$dest is in the way; remove it and run this again"; fi
  fi
  rm -rf "$STAGE"
  STAGE=""
  TAG="$tag"
}

# Points $INSTALL_DIR/current at versions/<tag> with one rename, where mv can replace a link.
set_current() {
  local link="$INSTALL_DIR/current" tmp="$INSTALL_DIR/.current.$$"
  if [ -d "$link" ] && [ ! -L "$link" ]; then die "$link is a folder in the way; remove it and run this again"; fi
  rm -f "$tmp"
  ln -s "versions/$1" "$tmp"
  mv -Tf "$tmp" "$link" 2>/dev/null || mv -hf "$tmp" "$link" 2>/dev/null || { rm -f "$link" && mv -f "$tmp" "$link"; }
}

# The tag `current` points at (older installs kept it in a file).
current_tag() {
  local link="$INSTALL_DIR/current" target
  if [ -L "$link" ]; then
    target="$(readlink "$link")"
    printf '%s' "${target##*/}"
  elif [ -f "$link" ]; then
    cat "$link"
  fi
}

# Removes the versions this install replaced, except any still running: an office, or the terminal
# host that keeps its workers alive across office restarts. Without pgrep nothing is removed.
prune_versions() {
  local keep="$1" dir real rc
  have pgrep || return 0
  for dir in "$VERSIONS"/v*; do
    [ -d "$dir" ] && [ "${dir##*/}" != "$keep" ] || continue
    real="$(cd "$dir" && pwd -P)"
    rc=0
    pgrep -f -- "$dir/" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ] || continue
    rc=0
    pgrep -f -- "$real/" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ] || continue
    rm -rf "$dir"
  done
}

# Puts an `agent-office` command on the PATH: a link to the current version's binary.
write_launcher() {
  local exe="$INSTALL_DIR/current/agent-office" target tmp
  [ -n "$BIN_DIR" ] || return 0
  target="$BIN_DIR/agent-office"
  # Ours are a link into the install, or the shell launcher that Node.js releases wrote.
  if [ -e "$target" ] || [ -L "$target" ]; then
    if ! { [ -L "$target" ] && [[ "$(readlink "$target")" == "$INSTALL_DIR/"* ]]; } &&
      ! grep -q "$MARKER" "$target" 2>/dev/null; then
      warn "left $target alone: this script didn't write it"
      return 0
    fi
  fi
  mkdir -p "$BIN_DIR"
  tmp="$target.tmp.$$"
  rm -f "$tmp"
  ln -s "$exe" "$tmp"
  mv -f "$tmp" "$target"
  case ":$PATH:" in
    *":$BIN_DIR:"*) LAUNCHER="agent-office" ;;
    *)
      LAUNCHER="$target"
      warn "$BIN_DIR isn't on your PATH. Add it to run ${BOLD}agent-office${RESET} directly next time."
      ;;
  esac
}

main() {
  trap cleanup EXIT
  check_requirements

  local tag="" tarball="${AGENT_OFFICE_TARBALL:-}" current
  current="$(current_tag)"
  if [ -n "$tarball" ]; then
    [ -f "$tarball" ] || die "no such file: $tarball"
  elif [ -n "${AGENT_OFFICE_VERSION:-}" ]; then
    tag="v${AGENT_OFFICE_VERSION#v}"
  else
    # Empty when GitHub can't be reached, or a mirror doesn't redirect: then the tarball says.
    tag="$(latest_tag)"
  fi
  if [ -n "$tag" ]; then valid_tag "$tag" || die "not a release version: $tag"; fi

  if [ -n "$tarball" ] || [ -z "$tag" ] || ! installed "$tag"; then
    if [ -z "$tarball" ] && [ -z "$tag" ] && [ -n "$current" ] && installed "$current" &&
      ! curl -fsI -o /dev/null "$RELEASES/latest/download/SHA256SUMS" 2>/dev/null; then
      warn "couldn't reach GitHub to look for a newer release; starting the installed $current"
      tag="$current"
    else
      install_release "$tag" "$tarball"
      tag="$TAG"
    fi
  fi
  set_current "$tag"
  prune_versions "$tag"
  write_launcher

  local exe="$INSTALL_DIR/current/agent-office"
  if [ "${AGENT_OFFICE_INSTALL_ONLY:-}" = 1 ]; then
    step "Agent Office $tag is installed. Start it with: ${LAUNCHER:-$exe}"
    return 0
  fi
  step "Starting Agent Office $tag"
  # Piped into bash (curl … | bash), stdin is the rest of this script: give the office the terminal
  # instead, so its first-run walkthrough can ask where projects go and which one to start with.
  if [ ! -t 0 ] && [ -t 1 ] && (: </dev/tty) 2>/dev/null; then exec "$exe" "$@" </dev/tty; fi
  exec "$exe" "$@"
}

main "$@"
