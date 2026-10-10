# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **template** for a per-project terminal dev container (Ubuntu 26.04, Helix,
evil-helix, Neovim, Python and Rust tooling, Claude Code, Orca's headless
server). It has no application code and no test suite. The "product" is the
Docker image, the editor configs baked into it, the `dev` lifecycle script, and
the docs. README.md explains what is installed and why; TIPS.md explains how to
drive the editors once inside.

## Where commands run

`./dev` runs on the **host** and needs Docker. Claude Code often runs *inside*
the container, where there is no `docker` binary and this checkout is reached
through a bind mount such as `/mount`. From there you cannot build or start the
image, so validate changes locally:

```sh
bash -n dev .devcontainer/config/bin/orca-server install-scripts/install.sh

# Load this checkout's Neovim config instead of the copy baked into the image
# (~/.config/nvim is a copy, not a link, so editing the repo does not change it)
XDG_CONFIG_HOME=$PWD/.devcontainer/config nvim --headless +qa
```

Host-side commands (run `./dev` with no arguments for the full list):

```sh
./dev setup <name> [--with-orca [--orca-port <port>] | --without-orca]
                   [--with-postgres | --without-postgres] [--force]
                               # render .devcontainer/docker-compose.yml from the template
./dev reconfigure [same options] # setup <current name> --force, name read from the file
./dev up                       # show build parameters, confirm, build if needed, start
./dev rebuild                  # same, but build --no-cache; keeps volumes
./dev attach                   # tmux session 'main' inside the container
./dev orca [addr] | orca-url | orca-log | orca-stop | orca-update
./dev mount <host-path> <name> | unmount <name>   # then ./dev up (recreates the container)
```

`install-scripts/install.sh -l|-c` installs the same Neovim setup on a plain
Ubuntu 22.04/24.04/26.04 machine without a container.

## How the pieces depend on each other

Several files are parsed by other files, so their format is a contract:

- **The Dockerfile is the single source of truth for versions.** `install.sh`
  reads `ARG NAME=value` lines with sed (`dockerfile_arg`), and reads the
  treesitter parser list from the one-line
  `require('nvim-treesitter').install({ ... })` bake step. Keep both on a single
  line in that form. If you change the parser list, also update the expected
  count (`-lt 12`) in the Dockerfile's verification step.
- **`docker-compose.yml.template` → `docker-compose.yml`.** `./dev setup`
  substitutes `__PROJECT_NAME__`, `__PROJECT_HOSTNAME__`, `__WITH_ORCA__`,
  `__WITH_POSTGRES__` and `__ORCA_PORT__`. The rendered file
  is gitignored and machine-specific; edit the template, never the rendered
  file. `dev` finds its own mount entries between the `# >>> extra mounts` /
  `# <<< extra mounts` markers. In a project without Orca, `setup` deletes
  everything between `# >>> orca only` / `# <<< orca only` (the published
  port). `orca_host_port` reads the host port from a `- "NNNN:6768"` line.
  Keep the markers and that port-line format intact.
- **Some values come from the environment at run time.** `find_ssh_agent` in
  `dev` exports `HOST_SSH_AUTH_SOCK` before any compose command, and the
  template interpolates it as the source of the `/ssh-agent` mount. That source
  is Docker Desktop's fixed path on macOS, `$SSH_AUTH_SOCK` on Linux, or
  `/dev/null` when there is no agent. Values that change between runs belong
  here, not in `setup`.
- **Configs are baked into the image** by `COPY` in the Dockerfile, so changes
  under `.devcontainer/config/` need `./dev rebuild`. The exception is
  `TIPS.md`, which is bind-mounted read-only to `~/.config/nvim/TIPS.md`.
- **TIPS.md's `## Quick reference` section is the Neovim startup screen and
  `:Tips` content**, rendered by `config/nvim/lua/devtips.lua`. That parser
  keeps two-column table rows, skips prose, and stops at the next `## `
  heading. A literal pipe inside a cell must be written `\|`.
- **`hx` and `ehx` are wrappers** (`config/bin/`) that each set
  `HELIX_RUNTIME` for their own process. Never export `HELIX_RUNTIME`
  globally: one editor would load the other's grammars. Both share
  `config/helix/languages.toml`; evil-helix only has its own `config.toml`.
- **Build parameters are chosen at `setup` and stored** as `build.args` in the
  rendered compose file. `setup --force` carries them across, as it does
  mounts. `up` and `rebuild` take no options. They read the parameters back
  (`orca_setting`, `postgres_setting`), show them in `confirm_build`, and ask
  before building. With no TTY on stdin they skip the question and build. A new parameter needs a
  placeholder in the template, flags and carry-over in `cmd_setup`, a line in
  `confirm_build`, and the usage text.
- **Orca is opt-in** (`setup --with-orca` → `WITH_ORCA: "true"` → `ARG
  WITH_ORCA`). Keep its step **last** in the Dockerfile. A changed build arg
  invalidates every `RUN` after its `ARG` line, so anywhere earlier, toggling
  Orca or bumping `ORCA_VERSION` would re-run the plugin and parser bake. A
  compose file rendered before the setting existed has no `WITH_ORCA` line, and
  the Dockerfile default (`false`) applies. The port is published only with
  Orca, because a published port must be free on the host even with nothing
  behind it. The Orca volumes and `orca-server` are present either way.
- **PostgreSQL is opt-in** the same way (`--with-postgres` → `ARG
  WITH_POSTGRES`). Its step sits just before Orca's. `config/bin/pg` runs it
  as `dev` with `initdb`/`pg_ctl`, one cluster per major version under the
  `postgres` volume (`~/.local/share/postgresql/<major>`). The image drops the
  package's `main` cluster and gives `/var/run/postgresql` (libpq's default
  socket directory) to `dev`; do not switch to `pg_ctlcluster`, whose config
  in `/etc/postgresql` would reset on every rebuild. Giving it to `dev` takes a
  `chown` *and* an override of the package's tmpfiles rule in
  `/etc/tmpfiles.d/postgresql-common.conf`. Any later `systemd-tmpfiles
  --create` re-applies the package's rule. systemd's postinst runs one, and
  systemd arrives with Orca's dependencies. Without the override the
  directory reverts to `postgres` and `pg start` fails.
- **Orca runtime:** `./dev orca` on the host works out the host's address (Tailscale if
  `tailscale status` succeeds, otherwise LAN) and calls `orca-server start` in
  the container. `up` and `rebuild` do the same through
  `start_services_after_up` when `WITH_ORCA` is `"true"`, with `--no-url`, and
  run `pg start` when `WITH_POSTGRES` is. Both are best effort: a failure
  there warns and `up` still succeeds. `dev` runs on macOS's bash 3.2, so no
  empty arrays under `set -u`. `orca-server` runs `orca-ide serve` under Xvfb in tmux session
  `orca`, logs to `~/.local/state/orca-server.log`, and reads the advertised
  endpoint and pairing URL back out of that log. Orca also runs a terminal
  daemon (`daemon-entry.js`) in a session of its own, which owns the agents'
  shells, possibly including the one you are running in. `orca-server stop`
  and `update` must stop only the tmux pane's process group and wait on that.
  Never `pkill orca-ide`. `orca-server update` installs the latest `.deb`
  from GitHub with `sudo apt-get` and restarts the server at its advertised
  address. That change lasts until the container is recreated, unless
  `ORCA_VERSION` is bumped. The container listens on 6768.
  The host publishes it on a per-project port, never 6768 itself, because
  Orca's desktop app already uses 6768. `ORCA_VERSION` in the Dockerfile pins
  the version.
- **Orca host ports:** `setup` fills `__ORCA_PORT__` through
  `choose_orca_port`. It takes `--orca-port` if given, else the port carried
  over from the old file, else the first free port from 16768 up. A port
  clashes (`port_clash`) when another compose project's container publishes it
  (`published_ports`, which includes stopped containers) or when something not
  belonging to this project accepts connections on it. `confirm_build` runs
  the same check again before every build. Everything Docker-dependent is best
  effort: `setup` still works when the daemon is down.

## Traps that shaped the design

Read these before adding volumes, paths or tools:

- **Every named-volume mountpoint must already exist in the image, owned by
  `dev`.** Otherwise Docker creates it owned by root and the user cannot write
  there. The cargo registry and the Orca state directories both hit this. When
  you add a volume, add its directory to the `mkdir -p` in the Dockerfile.
  Existing volumes keep their old ownership, so they also need
  `docker volume rm`.
- **`~/.claude.json` is a symlink** into the `claude-config` volume, created in
  the Dockerfile. `bashrc.extra` repairs it on every shell, because
  write-temp-then-rename saves replace the link with a plain file.
- **System-wide git settings** (`safe.directory = *` and delta as the pager)
  go in `/etc/gitconfig` via `git config --system`. `~/.config/git` is a
  volume, so anything written there at build time is hidden once the volume is
  mounted.
- **Architecture names differ per upstream:** Helix uses `x86_64`, evil-helix
  `amd64`, and tree-sitter `x64`. Each download step maps
  `dpkg --print-architecture` on its own. Builds must work on both amd64 and
  arm64.
- When you add a tool to the Dockerfile, check whether `install.sh` needs the
  same tool. It has its own per-release install functions, for example on
  22.04 it builds tree-sitter with cargo and fetches fzf and delta from
  upstream.

## Conventions

- Comments explain *why*, often at length. They record measured behaviour,
  exact error messages and rejected alternatives. Keep that density when you
  edit, and do not cut existing rationale.
- Prose and comments use British spelling (behaviour, honour).
- Behaviour changes usually come with matching updates to README.md (and
  TIPS.md for editor keys or workflows) in the same commit. README's "Known
  caveats" section records version pins and upstream breakage.
- IDEAS.md lists features that have not been built yet.
