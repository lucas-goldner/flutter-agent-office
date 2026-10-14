# Agent Office in a container, the way deploy/railway.sh runs it on Railway, deploy/fly.sh on Fly.io,
# deploy/dokploy.sh on Dokploy and deploy/coolify.sh on Coolify. Any Docker host works the same way:
# mount a volume at /data and publish port 22 (or the port in AGENT_OFFICE_SSHD_PORT, which
# deploy/fly.sh sets to 2222).
#
# The office listens on 127.0.0.1:4600 inside the container and is never published. sshd on port 22
# is the only way in: the keys in AGENT_OFFICE_ADMIN_KEYS get a shell as agentoffice, the user that
# runs the office, and teammates invited from the office log in as `office`, which can only open
# the tunnel. Everything that has to outlive a restart or a redeploy is on the volume (start.sh).
#
# The office itself is a release (one executable plus the web client, no Node.js), installed by
# this repository's install.sh while the image builds: the newest release of AGENT_OFFICE_REPO, the
# one in AGENT_OFFICE_VERSION (a tag like v0.1.68), or a release tarball in the build context named
# by AGENT_OFFICE_TARBALL (from `dart run tool/build.dart --pack`). A redeploy picks up a newer one.
#
# Build it from the repository root: docker build -f deploy/container/Dockerfile .
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
# sshd for the tunnels, tini to reap what workers leave behind, `ss` (iproute2) for the office to
# find the web servers workers start, jq for the Claude Code onboarding, and what workers need:
# git, the GitHub CLI (from GitHub's own apt repo, like deploy/provision.sh) and build tools.
RUN apt-get update \
  && apt-get install -y --no-install-recommends openssh-server sudo tini procps iproute2 jq ca-certificates curl git less build-essential python3 \
  && install -d -m 755 /etc/apt/keyrings \
  && curl -fsSLo /etc/apt/keyrings/githubcli-archive-keyring.gpg https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    >/etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*
ARG AGENT_OFFICE_REPO=lucas-goldner/flutter-agent-office
ARG AGENT_OFFICE_VERSION=
ARG AGENT_OFFICE_TARBALL=
COPY . /opt/agent-office
# Dokploy unpacks deploy/dokploy.sh's upload without file modes, so the scripts get theirs back here.
RUN chmod 755 /opt/agent-office/install.sh /opt/agent-office/deploy/container/*.sh \
  && AGENT_OFFICE_REPO="$AGENT_OFFICE_REPO" AGENT_OFFICE_VERSION="$AGENT_OFFICE_VERSION" \
    AGENT_OFFICE_TARBALL="${AGENT_OFFICE_TARBALL:+/opt/agent-office/$AGENT_OFFICE_TARBALL}" \
    /opt/agent-office/deploy/container/install.sh
EXPOSE 22
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/agent-office/deploy/container/start.sh"]
