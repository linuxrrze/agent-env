FROM ubuntu:26.04

# UTF-8 without needing the `locales` package/locale-gen
ENV LANG=C.UTF-8
# roamgate (formerly herdr-studio/herdr-gui) ships an in-app self-updater;
# this image is version-pinned by CI, so disable it to keep the baked-in
# release intact.
ENV ROAMGATE_DISABLE_UPDATE_CHECK=1

# Multi-arch (amd64 + arm64, built natively per arch by CI): every RUN that
# downloads a release binary maps `dpkg --print-architecture` to that
# project's own asset naming and fails on any other architecture.
#
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
  systemd-standalone-tmpfiles tini \
  python-is-python3 file rsync tmux sqlite3 zstd \
  iproute2 iputils-ping bind9-dnsutils netcat-openbsd \
  psmisc lsof strace \
  shellcheck yamllint pipx

# Debian/Ubuntu ship fd as `fdfind` (name clash with an older package);
# agents and docs call it `fd`.
ln -s /usr/bin/fdfind /usr/local/bin/fd

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
ARG NPM_VERSION=11.21.2
RUN << EORUN
set -euo pipefail

# --- Node.js + npm (official prebuilt binary; pinned & self-contained) -----
case "$(dpkg --print-architecture)" in
  amd64) NODE_ARCH=x64 ;;
  arm64) NODE_ARCH=arm64 ;;
  *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;;
esac
# Extracted straight into /usr/local so `npm -g` installs land in
# /usr/local/lib/node_modules with world-executable bins in /usr/local/bin.
curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -o /tmp/node.tar.xz
tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
rm -f /tmp/node.tar.xz

# Node's bundled npm lags behind on its own bundled deps (undici, tar,
# brace-expansion, ...) and Trivy flags those -- replace it in place with the
# pinned npm (NPM_VERSION, see .env.sample).
npm install -g "npm@${NPM_VERSION}"
test "$(npm --version)" = "$NPM_VERSION"
rm -rf /root/.npm
EORUN

ARG HERDR_VERSION=0.9.3
ARG HERDR_STUDIO_VERSION=0.7.13
RUN << EORUN
set -euo pipefail

case "$(dpkg --print-architecture)" in
  amd64) HERDR_ARCH=x86_64;  ROAMGATE_ARCH=x64 ;;
  arm64) HERDR_ARCH=aarch64; ROAMGATE_ARCH=arm64 ;;
  *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;;
esac

# --- herdr (the runtime your coding agents live on), pinned release binary --
# Pull the pinned GitHub release binary straight down (no `curl | sh`),
# mirroring how the Node tarball is handled above for reproducibility.
curl -fsSL "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-${HERDR_ARCH}" -o /usr/local/bin/herdr
chmod +x /usr/local/bin/herdr

# --- roamgate (web UI for herdr sessions), pinned release binary ------------
# Upstream renamed herdr-studio/herdr-gui to roamgate at v0.7.0 (repo
# powerfooI/roamgate). A standalone binary (embeds its own runtime; no Node or
# other deps needed at runtime). Pull the pinned GitHub release tarball
# (contains roamgate + a VERSION file) and install the binary, mirroring how
# the Node/herdr archives are handled above for reproducibility. The old
# herdr-gui name is kept as a symlink for compatibility.
curl -fsSL "https://github.com/powerfooI/roamgate/releases/download/v${HERDR_STUDIO_VERSION}/roamgate-v${HERDR_STUDIO_VERSION}-linux-${ROAMGATE_ARCH}.tar.xz" -o /tmp/roamgate.tar.xz
tar -xJf /tmp/roamgate.tar.xz -C /tmp "roamgate-linux-${ROAMGATE_ARCH}/roamgate"
install -m 0755 "/tmp/roamgate-linux-${ROAMGATE_ARCH}/roamgate" /usr/local/bin/roamgate
ln -sf /usr/local/bin/roamgate /usr/local/bin/herdr-gui
rm -rf /tmp/roamgate.tar.xz "/tmp/roamgate-linux-${ROAMGATE_ARCH}"
EORUN

ARG GLAB_VERSION=1.124.0
ARG TEA_VERSION=0.16.0
RUN << EORUN
set -euo pipefail

# --- glab (GitLab CLI) + tea (Gitea CLI), pinned release binaries ----------
# Version-pinned and tracked by CI (like herdr/roamgate above); both are
# checksum-verified against the release's own published sha256 before
# install. Both name their assets like dpkg (amd64/arm64).
ARCH=$(dpkg --print-architecture)
case "$ARCH" in amd64|arm64) ;; *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;; esac
GLAB_TGZ="glab_${GLAB_VERSION}_linux_${ARCH}.tar.gz"
curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/${GLAB_TGZ}" -o "/tmp/${GLAB_TGZ}"
curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/checksums.txt" -o /tmp/glab-checksums.txt
# awk drains the whole file (no early exit); an empty hash makes sha256sum fail.
echo "$(awk -v f="$GLAB_TGZ" '$2==f{print $1}' /tmp/glab-checksums.txt)  /tmp/${GLAB_TGZ}" | sha256sum -c -
tar -xzf "/tmp/${GLAB_TGZ}" -C /tmp bin/glab
install -m 0755 /tmp/bin/glab /usr/local/bin/glab
rm -rf "/tmp/${GLAB_TGZ}" /tmp/glab-checksums.txt /tmp/bin

TEA_XZ="tea-${TEA_VERSION}-linux-${ARCH}.xz"
curl -fsSL "https://gitea.com/gitea/tea/releases/download/v${TEA_VERSION}/${TEA_XZ}" -o "/tmp/${TEA_XZ}"
curl -fsSL "https://gitea.com/gitea/tea/releases/download/v${TEA_VERSION}/${TEA_XZ}.sha256" -o /tmp/tea.sha256
echo "$(cut -d' ' -f1 /tmp/tea.sha256)  /tmp/${TEA_XZ}" | sha256sum -c -
xz -dc "/tmp/${TEA_XZ}" > /usr/local/bin/tea
chmod 0755 /usr/local/bin/tea
rm -f "/tmp/${TEA_XZ}" /tmp/tea.sha256
EORUN

ARG HADOLINT_VERSION=2.15.1
ARG YQ_VERSION=4.54.1
ARG UV_VERSION=0.13.5
RUN << EORUN
set -euo pipefail

# --- hadolint, yq (mikefarah), uv: pinned release binaries ----------------
# Version-pinned and tracked by CI (like glab/tea above), each verified
# against the release's own published sha256 before install.
# From upstream, not Ubuntu: yq is a Go binary (Ubuntu's rebuilds lag Go
# security fixes -- the Trivy gate), Ubuntu's `yq` package is an unrelated
# jq wrapper with different syntax, and hadolint is not packaged at all.
# (actionlint was left out on purpose: its latest release, 1.7.12, is built
# with Go 1.26.1 and carries ~24 fixable HIGH stdlib CVEs.) uv lets the
# non-root user install Python tools (pip is PEP 668 externally-managed
# here, so a bare `pip install` fails).
# Every awk below drains its whole file (no early exit); an empty hash makes
# sha256sum fail.
GH=https://github.com
case "$(dpkg --print-architecture)" in
  amd64) HADOLINT_ARCH=x86_64; YQ_ARCH=amd64; UV_ARCH=x86_64 ;;
  arm64) HADOLINT_ARCH=arm64;  YQ_ARCH=arm64; UV_ARCH=aarch64 ;;
  *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;;
esac
curl -fsSL "${GH}/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-${HADOLINT_ARCH}" -o /tmp/hadolint
curl -fsSL "${GH}/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/checksums.sha256" -o /tmp/hadolint.sums
echo "$(awk -v f="hadolint-linux-${HADOLINT_ARCH}" '$2=="*"f || $2==f{print $1}' /tmp/hadolint.sums)  /tmp/hadolint" | sha256sum -c -
install -m 0755 /tmp/hadolint /usr/local/bin/hadolint
rm -f /tmp/hadolint /tmp/hadolint.sums

curl -fsSL "${GH}/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${YQ_ARCH}" -o /tmp/yq
# checksums-bsd lines: `SHA256 (yq_linux_<arch>) = <hash>`
curl -fsSL "${GH}/mikefarah/yq/releases/download/v${YQ_VERSION}/checksums-bsd" -o /tmp/yq.sums
echo "$(awk -v f="(yq_linux_${YQ_ARCH})" '$1=="SHA256" && $2==f{print $4}' /tmp/yq.sums)  /tmp/yq" | sha256sum -c -
install -m 0755 /tmp/yq /usr/local/bin/yq
rm -f /tmp/yq /tmp/yq.sums

UV_TGZ="uv-${UV_ARCH}-unknown-linux-gnu.tar.gz"
curl -fsSL "${GH}/astral-sh/uv/releases/download/${UV_VERSION}/${UV_TGZ}" -o "/tmp/${UV_TGZ}"
curl -fsSL "${GH}/astral-sh/uv/releases/download/${UV_VERSION}/${UV_TGZ}.sha256" -o /tmp/uv.sha256
echo "$(cut -d' ' -f1 /tmp/uv.sha256)  /tmp/${UV_TGZ}" | sha256sum -c -
tar -xzf "/tmp/${UV_TGZ}" -C /tmp
install -m 0755 "/tmp/uv-${UV_ARCH}-unknown-linux-gnu/uv" "/tmp/uv-${UV_ARCH}-unknown-linux-gnu/uvx" /usr/local/bin/
rm -rf "/tmp/${UV_TGZ}" /tmp/uv.sha256 "/tmp/uv-${UV_ARCH}-unknown-linux-gnu"
EORUN

# Shared, image-wide browser dir: Playwright's default (~/.cache/ms-playwright)
# would be hidden by the bind-mounted home.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
ARG PLAYWRIGHT_MCP_VERSION=0.0.83
RUN << EORUN
set -euo pipefail

# --- Headless browser: Playwright + Chromium headless shell + Playwright MCP -
# @playwright/mcp is the tracked pin; the `playwright` CLI is installed at the
# exact (often alpha) version that MCP release depends on, so both look for
# the same Chromium revision and only one browser lives in the image (the
# latest `playwright` release usually expects a different revision, and a
# mismatch fails with "Executable doesn't exist").
# Only chromium-headless-shell (~160 MB) -- what headless Chromium launches
# use; headed Chromium, Chrome, Firefox and WebKit are not installed.
# Ubuntu's own `chromium` package is a snap shim that can't work in a
# container. NB: Trivy scans the apt libs below but cannot see CVEs inside
# Playwright's downloaded Chromium -- keeping PLAYWRIGHT_MCP_VERSION current
# (CI does) is what keeps the browser patched.
PLAYWRIGHT_VERSION=$(npm view "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" dependencies.playwright)
test -n "$PLAYWRIGHT_VERSION"
npm install -g \
  "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" \
  "playwright@${PLAYWRIGHT_VERSION}"
# --with-deps apt-installs the shared libs + fonts Chromium needs (Playwright
# ships a per-distro list; ubuntu26.04 is supported).
apt-get update
playwright install --with-deps chromium-headless-shell
rm -rf /var/lib/apt/lists/* /var/cache/apt/*
# The mapped runtime user (PUID) can add other revisions next to the baked-in
# one, e.g. for a project pinning its own @playwright/test version.
chmod 1777 "$PLAYWRIGHT_BROWSERS_PATH"
[ ! -d "$PLAYWRIGHT_BROWSERS_PATH/.links" ] || chmod 1777 "$PLAYWRIGHT_BROWSERS_PATH/.links"

# Smoke test: actually render a page (catches missing shared libs).
playwright screenshot --browser=chromium 'data:text/html,<h1>ok</h1>' /tmp/pw-smoke.png
test -s /tmp/pw-smoke.png
rm -rf /tmp/pw-smoke.png /root/.npm
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
hadolint --version
yq --version
uv --version
playwright --version
command -v playwright-mcp
command -v fd python shellcheck yamllint pipx tmux rsync file
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
