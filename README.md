# Polyglot terminal dev container

Helix and Neovim running *inside* the container, with Python and Rust tooling,
Claude Code, and git. Source lives in a named Docker volume.

The design goal is that a laptop suspend cannot break your session. Nothing
here maintains a stateful connection from your Mac into the container. The
editor process runs inside, under tmux; you attach and detach at will.

## Layout

```
.devcontainer/
  Dockerfile              image: toolchains, editors, Claude Code
  docker-compose.yml      service + named volumes
  devcontainer.json       optional, for devcontainer-spec tooling
  config/
    helix/config.toml     Helix editor settings
    helix/languages.toml  LSP + DAP for Python and Rust
    nvim/init.lua         self-contained Neovim config
    tmux.conf             OSC 52 passthrough, sane defaults
    bashrc.extra          PATH, history persistence, `work` helper
dev                       lifecycle wrapper script
```

## First run

```sh
chmod +x dev
./dev up          # builds the image (10-15 min first time), starts container
./dev attach      # drops you into tmux inside the container
```

Then, inside:

```sh
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
claude                              # one-time browser OAuth
cd ~/src && git clone <your-repo>
```

Both the git config and the Claude credentials live in volumes, so you do this
once, not on every rebuild.

## Daily use

```sh
./dev attach
```

That is the whole recovery procedure after an overnight suspend. The tmux
session, your open buffers, running processes, and shell history are all
exactly where you left them, because none of them ever depended on a live
connection to your Mac.

If Docker Desktop itself was restarted, `./dev up` first, then attach. The
workspace volume is untouched by container restarts.

## What is installed

| Tool | Purpose |
|---|---|
| Helix 25.07.1 | Batteries-included editor, zero config needed |
| Neovim (upstream stable) | When you need the debugger or plugins |
| rustup + rust-analyzer, clippy, rustfmt | Rust |
| uv + Python 3.12 | Python interpreter and package management |
| basedpyright, ruff | Python LSP, lint, format |
| debugpy, lldb-dap | Debug adapters for Python and Rust |
| Claude Code | Native binary, no Node.js dependency |
| tmux, ripgrep, fd, fzf, jq, git-lfs | Supporting tools |
| Node.js 22 | Only for npx-based MCP servers |

## Choosing between the two editors

Both are installed deliberately. Helix (`hx`) needs no configuration and covers
editing, LSP, and navigation across every language with a server available.
Neovim (`nvim`) is here for debugging, which is the one area where Helix is
still explicitly experimental upstream and not a real replacement for what
PyCharm gave you. Reach for `nvim` when you need breakpoints, `hx` otherwise.

## Volumes

| Volume | Mounted at | Contents |
|---|---|---|
| `workspace` | `/home/dev/src` | Your cloned repositories |
| `cargo-registry` | `/usr/local/cargo/registry` | Crate downloads |
| `uv-cache` | `/home/dev/.cache/uv` | Python wheel cache |
| `nvim-state` | `/home/dev/.local/state/nvim` | Undo history, shada, shell history |
| `claude-config` | `/home/dev/.claude` | Claude Code credentials and settings |
| `git-config` | `/home/dev/.config/git` | Global git config |

`./dev rebuild` keeps all of these. Only `./dev nuke` destroys them.

### A note on UID/GID

The container user is `dev` (1000:1000) and the `dev` script does not forward
your host IDs. That is deliberate: macOS reports gid 20, which already exists
in Ubuntu as `dialout`, and forwarding it breaks the image build. Because your
source lives in a named volume rather than a bind mount, host/container ID
matching does not matter. If you switch to a bind mount on Linux, pass
`USER_UID`/`USER_GID` as build args to line them up.

### Why a named volume instead of a bind mount

On macOS, bind-mounted source goes through virtiofs, which is slow for the
many-small-file access patterns that language servers generate. Because the
editor and the LSP both run inside the container here, all of that traffic
would cross the virtiofs boundary. A named volume lives in the VM's own
filesystem and avoids it entirely. The tradeoff is that your source is not
directly visible in Finder; use `git` to move code in and out, which is
what you want anyway.

## Clipboard

Yanking inside the container reaches your Mac clipboard via OSC 52, configured
in all three of Helix, Neovim, and tmux. This requires a terminal that supports
it: Ghostty, WezTerm, kitty, and iTerm2 all do. Terminal.app does not.

Pasting *into* the container over OSC 52 mostly does not work; use your
terminal's normal paste (Cmd-V), which arrives as keystrokes.

## SSH agent forwarding

The compose file mounts `/run/host-services/ssh-auth.sock`, which is the fixed
path Docker Desktop for Mac exposes the host agent on. This lets you clone
private repos without copying keys into the image. Make sure your key is loaded
on the host first:

```sh
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

On Linux hosts this path does not exist; replace that volume line with
`${SSH_AUTH_SOCK}:/ssh-agent` instead.

## Customising

The editor configs are baked into the image, so `./dev rebuild` after editing
anything under `config/`. If you would rather iterate without rebuilding, add a
bind mount for the config directory in `docker-compose.yml`:

```yaml
      - ./config/helix:/home/dev/.config/helix
      - ./config/nvim:/home/dev/.config/nvim
```

## Known caveats

- **Helix debugging is experimental upstream.** The DAP blocks in
  `languages.toml` are provided but the feature is rough; use Neovim for
  serious debugging.
- **Helix has no plugin system in stable releases yet.** The Steel-based one is
  still an unmerged PR. If you need extensibility, that is Neovim's job here.
- **`nvim-treesitter` is pinned to `master`.** Its `main` branch rewrite drops
  the `configs.setup()` API and `:TSUpdateSync` used by this config and by the
  image build. Unpin only alongside a config rewrite.
- **debugpy lives in `/opt/debugpy`,** not your project venv. If your debugged
  code needs project dependencies visible to the adapter, run
  `uv pip install debugpy` inside the project venv and point
  `require("dap-python").setup(...)` at that interpreter instead.
- **Claude Code auto-updates in the background,** writing to `~/.local/bin`.
  That is not a volume, so an update is lost on rebuild and simply reapplies.
  Set `DISABLE_AUTOUPDATER=1` in the environment if you want version stability.
- **First build takes a while** because it compiles treesitter parsers and
  downloads two toolchains. Subsequent builds hit the layer cache.
