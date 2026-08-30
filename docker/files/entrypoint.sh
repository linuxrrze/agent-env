#!/usr/bin/env bash
set -euo pipefail

# Dev-sandbox entrypoint. Does three things, then hands off to your command:
#   1. Remaps the built-in `sandbox` user to the host user's id (PUID/PGID,
#      default 1000:1000) so files written into the mounted home are owned by
#      you on the host.
#   2. Starts an OpenSSH server (default port 2222) with public-key auth, so
#      you can `ssh -p 2222 sandbox@<host>` into the sandbox.
#   3. Runs the requested command (default: keep the container alive) as the
#      mapped user -- never as root.
#
# The container must start as ROOT (do not set `user:` in compose) so it can
# remap the user id and set up/start sshd; the workload itself is dropped to
# PUID via setpriv. `docker compose exec` therefore defaults to root -- use
# `-u $(id -u):$(id -g)` to act as yourself, or just SSH in.

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
SBOX_USER="sandbox"
HOME_DIR="${HOME_DIR:-/home/sandbox}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_PASSWORD_AUTH="${SSH_PASSWORD_AUTH:-no}"

current_uid="$(id -u)"

if [ "$current_uid" -eq 0 ]; then
  # --- 1. remap the sandbox user to the host user's id --------------------
  group_name="$(getent group "$PGID" | cut -d: -f1)" || true
  if [ -z "${group_name:-}" ]; then
    groupadd -g "$PGID" "$SBOX_USER"
    group_name="$SBOX_USER"
  fi
  if id "$SBOX_USER" >/dev/null 2>&1; then
    if [ "$(id -u "$SBOX_USER")" != "$PUID" ]; then
      usermod -u "$PUID" -g "$group_name" "$SBOX_USER"
    else
      usermod -g "$group_name" "$SBOX_USER"
    fi
  else
    # -p '*': disabled, not locked (a '!' shadow field would block pubkey
    # logins, see Dockerfile).
    useradd -m -u "$PUID" -g "$group_name" -s /bin/bash -c 'Sandbox user' -p '*' "$SBOX_USER"
  fi
  # The mounted home is normally already owned by the host user (= PUID); this
  # only matters when no home is mounted (image-owned dir left at uid 1000).
  chown "$PUID:$PGID" "$HOME_DIR"
  echo "codingenv: remapped '$SBOX_USER' to uid=$PUID gid=$PGID" >&2

  # Wipe stale /tmp from previous container runs, unless /tmp is its own
  # mount (tmpfs/bind from compose). Without this, agent scratch files would
  # accumulate in the container's writable overlay layer across restarts.
  # A user bind-mounted /tmp is a mountpoint and is left untouched.
  if ! awk '{print $2}' /proc/mounts | grep -qx /tmp; then
    find /tmp -mindepth 1 -delete 2>/dev/null || true
  fi

  # --- 2. start sshd -------------------------------------------------------
  # privsep dir (fresh each start -- /run is a tmpfs) + config drop-in. Host
  # keys were generated at build time (stable fingerprint).
  mkdir -p /run/sshd && chmod 755 /run/sshd
  ssh-keygen -A   # idempotent: fills in any host key missing from the image
  cat > /etc/ssh/sshd_config.d/60-codingenv.conf << CONF
Port ${SSH_PORT}
ListenAddress 0.0.0.0
PubkeyAuthentication yes
PasswordAuthentication ${SSH_PASSWORD_AUTH}
PermitRootLogin no
AllowUsers ${SBOX_USER}
UsePAM no
X11Forwarding no
AcceptEnv LANG LC_*
CONF
  /usr/sbin/sshd -D -e >> /var/log/sshd.log 2>&1 &
  echo "codingenv: sshd listening on port ${SSH_PORT} (user: ${SBOX_USER}, pubkey auth)" >&2
else
  echo "::warning:: not running as root; cannot remap user id or start sshd. Set the container to run as root (no 'user:' in compose)." >&2
fi

mkdir -p "$HOME_DIR"
if [ "$current_uid" -ne 0 ] && [ ! -w "$HOME_DIR" ]; then
  echo "::warning:: $HOME_DIR is not writable by uid $(id -u); make sure the mounted host home is owned by your user (see PUID/PGID)" >&2
fi
export HOME="$HOME_DIR"

# No command given -> keep the container alive (docker exec / ssh in).
if [ "$#" -eq 0 ]; then
  set -- sleep infinity
fi

# --- 3. run the workload as the mapped user (never as root) ---------------
if [ "$current_uid" -eq 0 ]; then
  # sshd keeps running as a child; when this process (the workload) exits the
  # container stops and the cgroup teardown takes sshd down with it.
  exec setpriv --reuid="$PUID" --regid="$PGID" --init-groups bash -c 'exec "$@"' _ "$@"
else
  exec "$@"
fi
