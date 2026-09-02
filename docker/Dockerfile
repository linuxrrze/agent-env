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
  systemd-standalone-tmpfiles tini

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

# ubuntu:26.04 ships /usr/bin/pebble (Canonical's container init) as a plain
# unregistered binary built with Go 1.26.5, which carries unpatched HIGH CVEs
# (e.g. CVE-2026-33818). This image never runs pebble -- tini (see
# ENTRYPOINT) is its init instead -- so drop it. Re-evaluate (and re-add) if
# an ubuntu:26.04 point release ships pebble built with Go >= 1.26.6 and it
# becomes load-bearing.
rm -f /usr/bin/pebble

# --- Sandbox user (remapped at runtime to the host user's id) --------------
# Some ubuntu base images ship a default `ubuntu` user at uid 1000; drop it so
# the sandbox user can take that id (no-op on the standard ubuntu image).
userdel ubuntu 2>/dev/null || true
groupadd -g 1000 sandbox
# -p '*': password DISABLED, not locked. Plain `useradd` leaves the shadow
# field as '!' (locked), and sshd with `UsePAM no` refuses public-key logins
# for locked accounts ("User ... not allowed because account is locked").
# '*' means "no password, public key OK" -- exactly what this image wants.
useradd -m -u 1000 -g sandbox -s /bin/bash -c 'Sandbox user' -p '*' sandbox

# Generate SSH host keys at build time into a dedicated dir (not /etc/ssh)
# so it can be bind-mounted for persistence (./fs/ssh-keys in
# docker-compose.yml.sample): this image is rebuilt on every tool upgrade,
# and baking fresh keys into /etc/ssh each time is what made clients see
# "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED" after upgrades. The
# entrypoint treats these build-time keys as fallback/seed only -- it fills
# in anything missing and never regenerates existing keys, and it points
# sshd at this dir via HostKey lines. Types/sizes match what
# `ssh-keygen -A` generates (OpenSSH 10.x: RSA 3072, ECDSA 256, Ed25519).
mkdir -p /var/lib/ssh-keys
chmod 700 /var/lib/ssh-keys
ssh-keygen -t rsa -b 3072 -N '' -q -f /var/lib/ssh-keys/ssh_host_rsa_key
ssh-keygen -t ecdsa -b 256 -N '' -q -f /var/lib/ssh-keys/ssh_host_ecdsa_key
ssh-keygen -t ed25519 -N '' -q -f /var/lib/ssh-keys/ssh_host_ed25519_key

# Sanity: everything we promised to install is actually present.
node --version
npm --version
python3 --version
command -v claude
command -v opencode
command -v herdr
command -v tini

rm -rf /var/lib/apt/lists/* /var/cache/apt/*
# npm keeps a cache of every downloaded tarball under /root/.npm during the
# global installs above (hundreds of MB). Drop it -- it's regenerated on
# first use, and the package docs in it trip trivy's secret scanner.
rm -rf /root/.npm
chmod +x /entrypoint.sh
EORUN

ENV HOME=/home/sandbox
WORKDIR /home/sandbox

# OpenSSH (see entrypoint; port configurable via SSH_PORT, default 2222)
EXPOSE 2222

# tini as the PID-1 wrapper: reaps orphaned agent subprocesses (zombies) even
# for deployments that forget `init: true` in compose. The entrypoint still
# runs as its direct child, so signal handling and container-stop semantics
# are unchanged.
ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
CMD ["sleep", "infinity"]
