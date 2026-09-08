# Polyglot terminal dev container

Helix, evil-helix and Neovim running *inside* the container, with Python and
Rust tooling, Claude Code, and git. Source lives in a named Docker volume.

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
    helix/config.toml       Helix editor settings
    helix/languages.toml    LSP + DAP for Python and Rust, shared with ehx
    evil-helix/config.toml  evil-helix settings; read only by `ehx`
    nvim/init.lua           self-contained Neovim config
    bin/hx, bin/ehx         wrappers that pin each editor to its own runtime
    tmux.conf               OSC 52 passthrough, sane defaults
    bashrc.extra            PATH, history persistence, `work` helper
dev                     lifecycle wrapper script
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
| Ubuntu 26.04 LTS | Base image: LLVM 21, GCC 15, system Python 3.14 |
| Helix 25.07.1 (`hx`) | Batteries-included editor, zero config needed |
| evil-helix (`ehx`) | Helix with Vim keybindings compiled in |
| Neovim (upstream stable, `nvim`) | When you need the debugger or plugins |
| rustup + rust-analyzer, clippy, rustfmt | Rust |
| uv + Python 3.12 | Python interpreter and package management |
| basedpyright, ruff | Python LSP, lint, format |
| debugpy, lldb-dap | Debug adapters for Python and Rust |
| Claude Code | Native binary, no Node.js dependency |
| tmux, ripgrep, fd, fzf, jq, git-lfs | Supporting tools |
| Node.js 22 | Only for npx-based MCP servers |

## Choosing between the three editors

All three are installed deliberately.

**`hx`** is mainline Helix. It needs no configuration and covers editing, LSP,
and navigation across every language with a server available. This is the
default and the one that stays current.

**`ehx`** is [evil-helix](https://github.com/usagi-flow/evil-helix), a soft
fork that compiles Vim keybindings into the editor instead of bolting them on
as config: `d`, `c`, `y`, `x`, `a`, the `i` text-object modifier, `w`/`W`/`e`/
`E`/`b`/`B`/`0`/`$`, and visual-line `V`. It is here as a softer landing from
Vim than Helix's selection-first model, where the object comes before the verb.
Set `editor.evil = false` in its config to turn the fork back into stock Helix
at runtime, which is a useful A/B when a binding surprises you.

**`nvim`** is here for debugging, which is the one area where Helix is still
explicitly experimental upstream and not a real replacement for what PyCharm
gave you. Reach for `nvim` when you need breakpoints.

`hx` and `ehx` are separate builds under separate prefixes, wrapped so each
gets its own `HELIX_RUNTIME` and its own `config.toml`. They deliberately
*share* `~/.config/helix/languages.toml`, so a language server or debug adapter
is configured once. The two use different themes purely so you can tell at a
glance which one you are in; evil-helix also calls the mode `VIS` rather than
`SEL`.

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
in Helix, evil-helix, Neovim, and tmux. This requires a terminal that supports
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
      - ./config/evil-helix:/home/dev/.config/evil-helix
      - ./config/nvim:/home/dev/.config/nvim
```

## Known caveats

- **Helix debugging is experimental upstream.** The DAP blocks in
  `languages.toml` are provided but the feature is rough; use Neovim for
  serious debugging.
- **Helix has no plugin system in stable releases yet.** The Steel-based one is
  still an unmerged PR. If you need extensibility, that is Neovim's job here.
- **evil-helix releases on demand, and demand has slowed.** The pinned
  `release-20250915` is the newest tag, and the fork saw only a handful of
  commits through 2026. It reports itself as `evil-helix (59215ec5, helix
  25.07.1)`, so today it sits on exactly the upstream release `hx` is pinned
  to and the two are in lockstep. That will not hold: when you bump
  `HELIX_VERSION`, expect `ehx` to fall behind, because a matching evil-helix
  tag may simply not exist. Check before assuming one does. The drift is
  survivable in that this is a soft fork rebased on upstream rather than a
  divergent editor.
- **Neovim stays on the upstream tarball even on 26.04.** Resolute packages
  0.11.6, which does run this config, but 0.12.0 landed just after the LTS
  freeze. An LTS will not rebase, so apt would hold you a minor version behind
  for five years while the plugin stack moves to 0.12 APIs.
- **26.04 replaces sudo with sudo-rs and coreutils with rust-coreutils**
  (`cp`, `mv` and `rm` are still GNU). This file's `ln -sf`, `chmod -R` and the
  `ls | head` in the lldb-dap probe now run through uutils implementations.
  They are meant to be drop-in, but this has not been through a full build yet,
  so if a step fails in a way that makes no sense, suspect that first.
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
