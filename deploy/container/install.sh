#!/usr/bin/env bash
# Sets up the container image at build time (deploy/container/Dockerfile): the office's release, the
# user that runs the office, the `office` user teammates tunnel in as, and sshd. start.sh does the
# rest at each start.
set -euo pipefail
ROOT=/opt/agent-office
PROVISION=$ROOT/deploy/provision.sh

# The office runs as agentoffice, like on a server set up by provision.sh (uid 1000), with its home
# on the volume.
groupadd --gid 1000 agentoffice
useradd --uid 1000 --gid agentoffice --home-dir /data/home --no-create-home --shell /bin/bash --password '*' agentoffice

# The release: one executable plus the web client, in /opt/agent-office/release (versions/<tag>,
# with `current` linking to it) and `agent-office` on the PATH. The image is rebuilt to update it,
# so the office doesn't upgrade itself in here.
AGENT_OFFICE_INSTALL_DIR=$ROOT/release AGENT_OFFICE_BIN_DIR=/usr/local/bin AGENT_OFFICE_INSTALL_ONLY=1 \
  bash $ROOT/install.sh
test -x $ROOT/release/current/agent-office

# The team helper, the tunnel-only login, sshd's limits for `office` and the Claude Code onboarding
# are provision.sh's own, so servers and containers share one copy of them.
take() { # <destination> <text on the heredoc's first line in provision.sh> <its closing tag>
  awk -v text="$2" -v tag="$3" -v q="'" '
    on && $0 == tag { exit }
    on { print }
    !on && index($0, text) && substr($0, length($0) - length(tag) - 3) == "<<" q tag q { on = 1 }
  ' "$PROVISION" >"$1"
  [[ -s "$1" ]] || { echo "install.sh: no <<'$3' heredoc for $2 in $PROVISION" >&2; exit 1; }
}
install -d -m 755 /usr/local/lib/agent-office /etc/ssh/sshd_config.d
take /usr/local/bin/agent-office-team '"$team_sh"' SH
take /usr/local/bin/agent-office-tunnel '"$tunnel_sh"' SH
take /etc/ssh/sshd_config.d/agent-office.conf '"$sshd_conf"' CONF
take /usr/local/lib/agent-office/onboard.sh '"$onboard_sh"' SH
chmod 755 /usr/local/bin/agent-office-team /usr/local/bin/agent-office-tunnel /usr/local/lib/agent-office/onboard.sh

# Teammates' keys go in office's authorized_keys, which the helper edits. It lives on the volume
# (start.sh makes /data/team), so invites survive redeploys.
useradd --create-home --shell /bin/sh --password '*' office
ln -s /data/team /home/office/.ssh
echo 'agentoffice ALL=(root) NOPASSWD: /usr/local/bin/agent-office-team' >/etc/sudoers.d/agent-office
chmod 440 /etc/sudoers.d/agent-office
visudo -cqf /etc/sudoers.d/agent-office

# Keys only. The host key is made on the volume at first start, so it's the same after every
# redeploy, and the one the package generated here would be baked into the image.
rm -f /etc/ssh/ssh_host_*
cat >/etc/ssh/sshd_config.d/00-container.conf <<'CONF'
# Written by deploy/container/install.sh
HostKey /etc/ssh/ssh_host_ed25519_key
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers agentoffice office
# The keys in AGENT_OFFICE_ADMIN_KEYS, written there by start.sh at every start. Commands run
# over ssh find Claude Code in ~/.local/bin, as the office does.
Match User agentoffice
    AuthorizedKeysFile .ssh/authorized_keys /etc/agent-office/admin_keys
    SetEnv PATH=/data/home/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONF
