# codingenv

A self-hosted **code-development sandbox**: an Ubuntu container with a basic
**Node.js/npm** and **Python** build environment, the **Claude Code**
(`claude`) and **opencode** CLIs plus **herdr** (the runtime your coding
agents live on) preinstalled, and **OpenSSH** on port 2222.
Your home (or just the tools' state dirs) is bind-mounted in and the sandbox
runs as **your host user id**, so anything it writes is owned by you on the
host (no root-owned litter, no `sudo` needed afterwards).

## Deploy

```sh
cd codingenv
cp docker-compose.yml.sample docker-compose.yml
```

Then edit `.env` (and/or `docker-compose.yml`):

- `PUID` / `PGID` → your host user's uid/gid (check with `id`). `1000:1000`
  is already the default for the first user on most systems.
- The home mount → point it at your real home (left side of the `volumes:`
  entry), e.g. `/home/YOURUSER:/home/sandbox`, or `export HOST_HOME=/home/YOURUSER`.
- Make sure you have an SSH public key in your `~/.ssh/authorized_keys` (the
  mounted home), so you can SSH in — see below.

```sh
docker compose up -d                     # start the sandbox (idles + sshd)
ssh -p 2222 sandbox@<host-ip>            # drop in over SSH, as yourself
# or via docker (exec defaults to root, so pass your uid:gid):
docker compose exec -u $(id -u):$(id -g) codingenv bash
# or run a tool directly (claude, opencode, and herdr are all on PATH):
docker compose run --rm codingenv claude
docker compose run --rm codingenv opencode
```

## How the user-id mapping works

The container intentionally starts as **root** (no `user:` in compose) so the
entrypoint can both remap the user id and set up sshd:

- It remaps the built-in `sandbox` user to `PUID`/`PGID`, then drops to that
  id with `setpriv` before running your command. Work never runs as root.
- Because the mapped uid **is** your host uid, and the mounted home is owned
  by that uid, files the sandbox writes are owned by you on the host with no
  runtime `chown`.
- `docker compose exec` defaults to **root** (the container's configured
  user), so pass `-u $(id -u):$(id -g)` to act as yourself — or just SSH in,
  which logs you in as `sandbox` (= your uid) automatically.

The entrypoint reads `PUID`, `PGID` (default `1000`), `HOME_DIR`
(default `/home/sandbox`), `SSH_PORT` (default `2222`) and
`SSH_PASSWORD_AUTH` (default `no`).

## SSH access

`sshd` runs on `SSH_PORT` (default **2222**), public-key authentication only,
login user **`sandbox`** (your mapped id). It reads `~/.ssh/authorized_keys`
from the mounted home, so any key you already trust there works:

```sh
ssh -p 2222 sandbox@<host-ip>
```

- Host keys are generated at build time, so the fingerprint is stable across
  restarts.
- `~/.ssh` must be `700` and `authorized_keys` `600` (ssh `StrictModes`); a
  normal user home already satisfies this.
- To (not recommended) allow password logins, set `SSH_PASSWORD_AUTH=yes` in
  `.env` and run `docker compose exec codingenv passwd sandbox`.

## Persisting config, tokens & caches

The container is ephemeral (recreated on every image update), so anything you
care about must live on a bind mount. Two options are in
`docker-compose.yml.sample`:

- **Option A (recommended)** — mount your whole home. Every tool keeps its
  state under your home, so one mount persists it all.
- **Option B (minimal)** — mount only the specific state dirs (under
  `./fs/`, gitignored), if you don't want the whole home exposed to the
  sandbox.

Where each tool keeps state:

| Tool        | What                     | Path                          | Relocatable via        |
|-------------|--------------------------|-------------------------------|------------------------|
| Claude Code | config, auth, projects   | `~/.claude.json`              | `CLAUDE_CONFIG_DIR`    |
| Claude Code | projects, todos, cache   | `~/.claude/`                  | `CLAUDE_CONFIG_DIR`    |
| opencode    | global config            | `~/.config/opencode/`         | `XDG_CONFIG_HOME`      |
| opencode    | auth tokens, data        | `~/.local/share/opencode/`    | `XDG_DATA_HOME`        |
| opencode    | cache                    | `~/.cache/opencode/`          | `XDG_CACHE_HOME`       |
| (shared)    | npm build cache          | `~/.npm/`                     | `npm config cache`     |
| (shared)    | pip build cache          | `~/.cache/pip/`               | `PIP_CACHE_DIR`        |

Notes:

- Claude Code also honours `ANTHROPIC_API_KEY` (an env var, not stored on
  disk) for API-key auth; subscription/OAuth credentials live in
  `~/.claude.json` / `~/.claude/`.
- If you use Option B, create the `./fs/...` host dirs first and make sure
  they're owned by your host user (they will be, if you `mkdir` them
  yourself).
- The npm/pip caches are optional; mounting them just makes repeat
  `npm install` / `pip install` faster.

## Build & version tracking

`CLAUDE_VERSION`, `OPENCODE_VERSION`, `HERDR_VERSION` (and `NODE_VERSION`)
live in `.env` and are passed to the build. The CI workflow
[`.gitea/workflows/codingenv-rebuild.yml`](../.gitea/workflows/codingenv-rebuild.yml):

- checks nightly for new releases of all three tools -- `@anthropic-ai/claude-code`
  and `opencode-ai` on npm, `herdr` on GitHub -- and when any moves it
  rebuilds, **scans the image with Trivy** (fails on fixable critical/high
  CVEs), pushes, and bumps the tracked versions in `.env` +
  `.codingenv-version` on its own.
- always rebuilds on a push to `codingenv/docker/` (even without a version
  change).

The image targets **amd64** (the Node tarball and the `herdr` binary are both
pinned for x86_64).

To rebuild locally:

```sh
docker compose build
```
