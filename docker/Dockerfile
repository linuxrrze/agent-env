FROM ubuntu:26.04
ARG NODE_VERSION=24.20.0
ARG CLAUDE_VERSION=latest
ARG OPENCODE_VERSION=latest
ARG HERDR_VERSION=0.8.2

# UTF-8 without needing the `locales` package/locale-gen
ENV LANG=C.UTF-8

COPY files/entrypoint.sh /entrypoint.sh

RUN << EORUN
set -euo pipefail

# Skip docs/man pages -- image-size trimming, in place before the first
# package unpacks anything under /usr/share.
{ echo 'path-exclude=/usr/share/doc/*'; \
  echo 'path-exclude=/usr/share/man/*'; \
  echo 'path-exclude=/usr/share/groff/*'; \
  echo 'path-exclude=/usr/share/info/*'; } > /etc/dpkg/dpkg.cfg.d/01_nodoc
echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections

apt-get update
apt-get -y dist-upgrade
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg \
  build-essential pkg-config \
  git openssh-client openssh-server \
  python3 python3-pip python3-venv python3-dev python3-setuptools python3-wheel \
  less vim tree jq unzip zip ripgrep fd-find \
  systemd-standalone-tmpfiles

# --- Node.js + npm (official prebuilt binary; pinned & self-contained) -----
# Extracted straight into /usr/local so `npm -g` installs land in
# /usr/local/lib/node_modules with world-executable bins in /usr/local/bin.
curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o /tmp/node.tar.xz
tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
rm -f /tmp/node.tar.xz

# --- The dev tools (claude + opencode), version-pinned by CI ---------------
npm install -g \
  "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
  "opencode-ai@${OPENCODE_VERSION}"

# --- herdr (the runtime your coding agents live on), pinned release binary --
# amd64. Pull the pinned GitHub release binary straight down (no `curl | sh`),
# mirroring how the Node tarball is handled above for reproducibility.
curl -fsSL "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-x86_64" -o /usr/local/bin/herdr
chmod +x /usr/local/bin/herdr

# --- Sandbox user (remapped at runtime to the host user's id) --------------
# Some ubuntu base images ship a default `ubuntu` user at uid 1000; drop it so
# the sandbox user can take that id (no-op on the standard ubuntu image).
userdel ubuntu 2>/dev/null || true
groupadd -g 1000 sandbox
useradd -m -u 1000 -g sandbox -s /bin/bash -c 'Sandbox user' sandbox

# Generate SSH host keys at build time so the host-key fingerprint is stable
# across container restarts (no "WARNING: REMOTE HOST IDENTIFICATION HAS
# CHANGED" prompts on the client).
ssh-keygen -A

# Sanity: everything we promised to install is actually present.
node --version
npm --version
python3 --version
command -v claude
command -v opencode
command -v herdr

rm -rf /var/lib/apt/lists/* /var/cache/apt/*
chmod +x /entrypoint.sh
EORUN

ENV HOME=/home/sandbox
WORKDIR /home/sandbox

# OpenSSH (see entrypoint; port configurable via SSH_PORT, default 2222)
EXPOSE 2222

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
