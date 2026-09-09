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
  # Host keys live in /var/lib/ssh-keys/ -- bind-mounted from the host
  # (./fs/ssh-keys in docker-compose.yml.sample) so the fingerprint stays
  # stable across image rebuilds, not just restarts. A bind mount replaces
  # whatever the image baked into that dir, so on first start (fresh host
  # dir) there is nothing to seed from: generate any missing key here,
  # same types/sizes as the build-time seed (OpenSSH 10.x `ssh-keygen -A`:
  # RSA 3072, ECDSA 256, Ed25519). Existing keys are kept as-is, never
  # regenerated -- that is the whole point.
  #
  # Without the mount this dir holds the image's build-time keys, i.e. the
  # old behaviour (stable across restarts, fresh keys on each image
  # upgrade) is preserved.
  SSH_KEYS_DIR=/var/lib/ssh-keys
  mkdir -p "$SSH_KEYS_DIR" && chmod 700 "$SSH_KEYS_DIR"
  generate_host_key() { # $1=key file  $2=type  $3=bits (empty for ed25519)
    if [ -f "$1" ]; then
      return 0
    fi
    if [ -n "${3:-}" ]; then
      ssh-keygen -t "$2" -b "$3" -N '' -q -f "$1"
    else
      ssh-keygen -t "$2" -N '' -q -f "$1"
    fi
  }
  generate_host_key "${SSH_KEYS_DIR}/ssh_host_rsa_key"     rsa 3072
  generate_host_key "${SSH_KEYS_DIR}/ssh_host_ecdsa_key"   ecdsa 256
  generate_host_key "${SSH_KEYS_DIR}/ssh_host_ed25519_key" ed25519
  # privsep dir (fresh each start -- /run is a tmpfs) + config drop-in.
  # Declaring HostKey overrides sshd's compiled-in /etc/ssh defaults, and
  # sshd aborts startup on a HostKey line whose file is missing -- so list
  # only the keys that actually exist.
  mkdir -p /run/sshd && chmod 755 /run/sshd
  {
    echo "Port ${SSH_PORT}"
    echo "ListenAddress 0.0.0.0"
    echo "PubkeyAuthentication yes"
    echo "PasswordAuthentication ${SSH_PASSWORD_AUTH}"
    echo "PermitRootLogin no"
    echo "AllowUsers ${SBOX_USER}"
    echo "UsePAM no"
    echo "X11Forwarding no"
    echo "AcceptEnv LANG LC_*"
    for t in rsa ecdsa ed25519; do
      if [ -f "${SSH_KEYS_DIR}/ssh_host_${t}_key" ]; then
        echo "HostKey ${SSH_KEYS_DIR}/ssh_host_${t}_key"
      fi
    done
  } > /etc/ssh/sshd_config.d/60-codingenv.conf
  # -e sends sshd's logs to stderr (not syslog) so they show up in
  # `docker logs` / compose logs; the container's stderr is the log sink.
  /usr/sbin/sshd -D -e 2>&1 &
  echo "codingenv: sshd listening on port ${SSH_PORT} (user: ${SBOX_USER}, pubkey auth)" >&2
else
  echo "::warning:: not running as root; cannot remap user id or start sshd. Set the container to run as root (no 'user:' in compose)." >&2
fi

mkdir -p "$HOME_DIR"
if [ "$current_uid" -ne 0 ] && [ ! -w "$HOME_DIR" ]; then
  echo "::warning:: $HOME_DIR is not writable by uid $(id -u); make sure the mounted host home is owned by your user (see PUID/PGID)" >&2
fi
export HOME="$HOME_DIR"

# --- herdr + herdr-gui (Herdr Studio) auto-start ---------------------------
# Start the herdr background server first (it creates
# $HOME/.config/herdr/herdr-client.sock, which herdr-gui needs to render
# sessions), then the Herdr Studio web UI on 0.0.0.0:HERDR_STUDIO_PORT. Run
# both as the mapped sandbox user (PUID), not root, so the herdr socket lives
# in the user-owned mounted home and a later `herdr` attach / the studio can
# use it. Background services: the requested command still runs in the
# foreground. HERDR_STUDIO_ENABLED=no skips both; default yes.
HERDR_STUDIO_ENABLED="${HERDR_STUDIO_ENABLED:-yes}"
HERDR_STUDIO_PORT="${HERDR_STUDIO_PORT:-8787}"
HERDR_STUDIO_PASSWORD="${HERDR_STUDIO_PASSWORD:-sandbox}"
HERDR_CLIENT_SOCK="${HOME_DIR}/.config/herdr/herdr-client.sock"
if [ "${HERDR_STUDIO_ENABLED,,}" = "yes" ]; then
  if [ "$current_uid" -eq 0 ]; then
    as_sandbox() { setpriv --reuid="$PUID" --regid="$PGID" --init-groups env HOME="$HOME_DIR" "$@"; }
  else
    as_sandbox() { env HOME="$HOME_DIR" "$@"; }
  fi
  as_sandbox herdr server >/var/log/herdr-server.log 2>&1 &
  # Wait for the render socket herdr-gui connects to (bounded, so a herdr
  # startup failure can never hang the container).
  for _ in $(seq 1 20); do
    if [ -S "$HERDR_CLIENT_SOCK" ]; then break; fi
    sleep 0.5
  done
  if [ -S "$HERDR_CLIENT_SOCK" ]; then
    as_sandbox herdr-gui --host 0.0.0.0 --port "$HERDR_STUDIO_PORT" --password "$HERDR_STUDIO_PASSWORD" \
      >/var/log/herdr-gui.log 2>&1 &
    echo "codingenv: herdr-gui (Herdr Studio) on http://0.0.0.0:${HERDR_STUDIO_PORT} (login password: HERDR_STUDIO_PASSWORD, default 'sandbox')" >&2
  else
    echo "::warning:: ${HERDR_CLIENT_SOCK} not present; herdr-gui not started (see /var/log/herdr-server.log)" >&2
  fi
fi

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
