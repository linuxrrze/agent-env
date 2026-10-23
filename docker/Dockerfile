FROM ubuntu:26.04

# UTF-8 without needing the `locales` package/locale-gen
ENV LANG=C.UTF-8
# roamgate (formerly herdr-studio/herdr-gui) ships an in-app self-updater;
# this image is version-pinned by CI, so disable it to keep the baked-in
# release intact.
ENV ROAMGATE_DISABLE_UPDATE_CHECK=1

# Layers ordered from least to most often changing, each ARG declared right
# above the one RUN that uses it (a changed ARG value invalidates every RUN
# after its declaration): a CLI bump -- the common case, near-daily -- only
# rebuilds the npm layer and reuses the system/Node/herdr layers.
#
# System packages + users + SSH host keys. APT_REFRESH (CI passes the date)
# re-runs this layer -- and its dist-upgrade -- at least once a day, so
# Ubuntu security updates keep landing even while it is otherwise cached.
ARG APT_REFRESH=
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
  less vim tree jq unzip zip ripgrep fd-find screen \
  systemd-standalone-tmpfiles tini

# --- GitHub CLI (gh), from GitHub's official apt repo -----------------------
# Not version-pinned/tracked by CI: like the Ubuntu packages above it lands at
# its latest release whenever this layer re-runs (APT_REFRESH: on the first
# rebuild of each day), so its Go stdlib stays current for the Trivy gate.
# Ubuntu's own `gh` package lags upstream by months.
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod 644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get update
apt-get install -y --no-install-recommends gh

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

rm -rf /var/lib/apt/lists/* /var/cache/apt/*
EORUN

ARG NODE_VERSION=24.20.0
RUN << EORUN
set -euo pipefail

# --- Node.js + npm (official prebuilt binary; pinned & self-contained) -----
# Extracted straight into /usr/local so `npm -g` installs land in
# /usr/local/lib/node_modules with world-executable bins in /usr/local/bin.
curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o /tmp/node.tar.xz
tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
rm -f /tmp/node.tar.xz
EORUN

ARG HERDR_VERSION=0.9.3
ARG HERDR_STUDIO_VERSION=0.7.13
RUN << EORUN
set -euo pipefail

# --- herdr (the runtime your coding agents live on), pinned release binary --
# amd64. Pull the pinned GitHub release binary straight down (no `curl | sh`),
# mirroring how the Node tarball is handled above for reproducibility.
curl -fsSL "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-x86_64" -o /usr/local/bin/herdr
chmod +x /usr/local/bin/herdr

# --- roamgate (web UI for herdr sessions), pinned release binary ------------
# Upstream renamed herdr-studio/herdr-gui to roamgate at v0.7.0 (repo
# powerfooI/roamgate). A standalone binary (embeds its own runtime; no Node or
# other deps needed at runtime). amd64: pull the pinned GitHub release tarball
# (contains roamgate + a VERSION file) and install the binary, mirroring how
# the Node/herdr archives are handled above for reproducibility. The old
# herdr-gui name is kept as a symlink for compatibility.
curl -fsSL "https://github.com/powerfooI/roamgate/releases/download/v${HERDR_STUDIO_VERSION}/roamgate-v${HERDR_STUDIO_VERSION}-linux-x64.tar.xz" -o /tmp/roamgate.tar.xz
tar -xJf /tmp/roamgate.tar.xz -C /tmp roamgate-linux-x64/roamgate
install -m 0755 /tmp/roamgate-linux-x64/roamgate /usr/local/bin/roamgate
ln -sf /usr/local/bin/roamgate /usr/local/bin/herdr-gui
rm -rf /tmp/roamgate.tar.xz /tmp/roamgate-linux-x64
EORUN

ARG GLAB_VERSION=1.124.0
ARG TEA_VERSION=0.16.0
RUN << EORUN
set -euo pipefail

# --- glab (GitLab CLI) + tea (Gitea CLI), pinned release binaries ----------
# Version-pinned and tracked by CI (like herdr/roamgate above); both are
# checksum-verified against the release's own published sha256 before
# install. amd64 only.
GLAB_TGZ="glab_${GLAB_VERSION}_linux_amd64.tar.gz"
curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/${GLAB_TGZ}" -o "/tmp/${GLAB_TGZ}"
curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/checksums.txt" -o /tmp/glab-checksums.txt
# awk drains the whole file (no early exit); an empty hash makes sha256sum fail.
echo "$(awk -v f="$GLAB_TGZ" '$2==f{print $1}' /tmp/glab-checksums.txt)  /tmp/${GLAB_TGZ}" | sha256sum -c -
tar -xzf "/tmp/${GLAB_TGZ}" -C /tmp bin/glab
install -m 0755 /tmp/bin/glab /usr/local/bin/glab
rm -rf "/tmp/${GLAB_TGZ}" /tmp/glab-checksums.txt /tmp/bin

TEA_XZ="tea-${TEA_VERSION}-linux-amd64.xz"
curl -fsSL "https://gitea.com/gitea/tea/releases/download/v${TEA_VERSION}/${TEA_XZ}" -o "/tmp/${TEA_XZ}"
curl -fsSL "https://gitea.com/gitea/tea/releases/download/v${TEA_VERSION}/${TEA_XZ}.sha256" -o /tmp/tea.sha256
echo "$(cut -d' ' -f1 /tmp/tea.sha256)  /tmp/${TEA_XZ}" | sha256sum -c -
xz -dc "/tmp/${TEA_XZ}" > /usr/local/bin/tea
chmod 0755 /usr/local/bin/tea
rm -f "/tmp/${TEA_XZ}" /tmp/tea.sha256
EORUN

ARG CLAUDE_VERSION=latest
ARG OPENCODE_VERSION=latest
RUN << EORUN
set -euo pipefail

# --- The dev tools (claude + opencode), version-pinned by CI ---------------
npm install -g \
  "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
  "opencode-ai@${OPENCODE_VERSION}"

# Sanity: everything we promised to install is actually present.
node --version
npm --version
python3 --version
command -v claude
command -v opencode
command -v herdr
command -v roamgate
roamgate --version
gh --version
glab --version
tea --version
command -v tini
command -v /usr/sbin/sshd

# npm keeps a cache of every downloaded tarball under /root/.npm during the
# global installs above (hundreds of MB). Drop it -- it's regenerated on
# first use, and the package docs in it trip trivy's secret scanner.
rm -rf /root/.npm
EORUN

# The entrypoint last: editing it rebuilds nothing above.
COPY --chmod=755 files/entrypoint.sh /entrypoint.sh

ENV HOME=/home/sandbox
WORKDIR /home/sandbox

# OpenSSH (see entrypoint; port configurable via SSH_PORT, default 2222)
EXPOSE 2222
# roamgate web UI (formerly herdr-studio/herdr-gui), auto-started by the
# entrypoint (HERDR_STUDIO_ENABLED, default yes; port via HERDR_STUDIO_PORT,
# default 8787)
EXPOSE 8787

# tini as the PID-1 wrapper: reaps orphaned agent subprocesses (zombies) even
# for deployments that forget `init: true` in compose. The entrypoint still
# runs as its direct child, so signal handling and container-stop semantics
# are unchanged.
ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
CMD ["sleep", "infinity"]
