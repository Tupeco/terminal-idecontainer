# Polyglot terminal dev container

Helix, evil-helix and Neovim running *inside* the container, with Python and
Rust tooling, Claude Code, and git. Source lives in a named Docker volume.

The design goal is that a laptop suspend cannot break your session. Nothing
here maintains a stateful connection from your Mac into the container. The
editor process runs inside, under tmux; you attach and detach at will.

This is a **template**, not a single environment: copy the repo per project and
run `./dev setup <project-name>`. See [Using this as a
template](#using-this-as-a-template).

## Layout

```
.devcontainer/
  Dockerfile              image: toolchains, editors, Claude Code
  docker-compose.yml.template
                          service + named volumes, with the project name
                          left as a placeholder
  docker-compose.yml      rendered from it by `./dev setup`; gitignored
  devcontainer.json       optional, for devcontainer-spec tooling
  config/
    helix/config.toml       Helix editor settings
    helix/languages.toml    LSP + DAP for Python and Rust, shared with ehx
    evil-helix/config.toml  evil-helix settings; read only by `ehx`
    nvim/init.lua           Neovim config
    nvim/lua/devtips.lua    renders TIPS.md as `:Tips` and the startup screen
    nvim/lua/occurrences.lua  <leader><CR> occurrence highlighting
    nvim/lua/termjump.lua   gf / ctrl-click on paths in terminal buffers
    bin/hx, bin/ehx         wrappers that pin each editor to its own runtime
    tmux.conf               OSC 52 passthrough, sane defaults
    bashrc.extra            PATH, history persistence, `work` helper
install-scripts/
  install.sh            the same Neovim setup on a plain Ubuntu machine,
                        without the container; see below
mount/                  bind-mounted at /mount inside; gitignored
dev                     lifecycle wrapper script
TIPS.md                 how to drive the tools once you are inside; also
                        bind-mounted, and rendered in-editor by `:Tips`
```

Run `./dev` with no arguments for the full command list.

## First run

```sh
chmod +x dev
./dev setup myproject   # renders docker-compose.yml for this project
./dev up                # builds the image (10-15 min first time), starts it
./dev attach            # drops you into tmux inside the container
```

Then, inside:

```sh
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
claude                              # one-time browser OAuth
cd ~/src && git clone <your-repo>
```

Both the git config and the Claude login live in volumes, so you do this once
per project, not on every rebuild.

## Using this as a template

Copy the repo, name it, start it:

```sh
cp -R idecontainer ~/git/newthing && cd ~/git/newthing
./dev setup newthing
./dev up
```

`setup` renders `.devcontainer/docker-compose.yml` from
`docker-compose.yml.template`, substituting the project name. That name becomes
the compose project name, and compose prefixes every named volume with it, so
`newthing_workspace` and `otherthing_workspace` are simply different volumes.
Nothing else needs renaming, and two copies never collide: separate source,
separate caches, separate git identity, separate Claude Code login and history.

The image tag is per-project too (`newthing-dev:latest`). Each copy owns its
Dockerfile and will drift as you add packages; a shared tag would let one
project's rebuild silently swap out the image another project is running.

The rendered file is gitignored, because it holds this machine's project name
and the absolute host paths from `./dev mount`. If you change the template
later — after pulling template updates into a project — re-render with:

```sh
./dev setup newthing --force
```

which rewrites the file and carries your mount entries across. Without
`--force`, `setup` refuses to overwrite.

Project names follow compose's own rule: lowercase letters, digits, dashes and
underscores, starting with a letter or digit. `setup` checks this up front so
you get an explanation rather than a compose error three commands later.

## Sharing files with the host

Source deliberately lives in a volume you cannot see from Finder (see [Why a
named volume](#why-a-named-volume-instead-of-a-bind-mount)), so there are two
bind mounts for the cases where the boundary needs to be crossed.

**`<repo>/mount` is always available at `/mount` inside the container.** It is
the general-purpose exchange: context to hand to Claude, generated artifacts
worth keeping, or a clone on the host that you commit into from inside and push
from outside. It is gitignored, and `./dev up` creates it if it is missing.

**Anything else, on demand:**

```sh
./dev mount ~/data/corpus corpus   # -> /other-mounts/corpus
./dev mount                        # list what is mounted
./dev unmount corpus
```

`mount` writes the entry into `docker-compose.yml` between two marker comments,
resolving the host path to an absolute one so the entry does not depend on
where you ran the command. Run `./dev up` afterwards to apply it; that recreates
the container, which is the one operation here that does discard your tmux
session.

Git repositories reached through either mount are owned by the host user rather
than by `dev`, which git rejects as "dubious ownership" the moment you try to
commit. The image sets `safe.directory = *` in `/etc/gitconfig` to switch that
check off, on the grounds that this is a single-user container where every
mounted path is deliberately yours. Narrow it to specific paths there if you
would rather.

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
| Neovim (upstream stable, `nvim`) | When you need the debugger, a project tree, or plugins |
| rustup + rust-analyzer, clippy, rustfmt | Rust |
| uv + Python 3.12 | Python interpreter and package management |
| basedpyright, ruff | Python LSP, lint, format |
| debugpy, lldb-dap | Debug adapters for Python and Rust |
| Claude Code | Native binary, no Node.js dependency |
| delta | Side-by-side `git diff`, `n`/`N` between files |
| tmux, ripgrep, fd, fzf, jq, git-lfs | Supporting tools |
| man-db, manpages, bash-completion | Working `man` and tab completion; see TIPS.md |
| satellite.nvim | PyCharm-style marker bar: diagnostics, git hunks and symbol occurrences on the scrollbar |
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
gave you. Reach for `nvim` when you need breakpoints, a whole-repo diff, or the
project tree: `nvim .` in a repo opens a file tree beside an editor window. See
[TIPS.md](TIPS.md).

`hx` and `ehx` are separate builds under separate prefixes, wrapped so each
gets its own `HELIX_RUNTIME` and its own `config.toml`. They deliberately
*share* `~/.config/helix/languages.toml`, so a language server or debug adapter
is configured once. The two use different themes purely so you can tell at a
glance which one you are in; evil-helix also calls the mode `VIS` rather than
`SEL`.

## Comparing revisions

The PyCharm habit of comparing the whole repo between two branches or tags,
with a file list and a keystroke to move between changed files, has a direct
equivalent in Neovim:

```vim
:DiffviewOpen main..feature        " branch vs branch
:DiffviewOpen v1.0..v2.0           " tag vs tag
:DiffviewOpen origin/main...HEAD   " merge base, i.e. what a PR would show
:DiffviewOpen HEAD~5               " the last five commits
```

A file panel runs down the left, the diff is side-by-side on the right, and
`<tab>` / `<s-tab>` move to the next and previous changed file without going
back to the panel. `<leader>b` hides the panel when you want the full width,
`g?` lists every binding. There are leader mappings for the common entries:

| Key | Does |
|---|---|
| `<leader>gd` | Diff the working tree |
| `<leader>gc` | Prompts `:DiffviewOpen ` — type a revision and press enter |
| `<leader>gh` | History for the current file |
| `<leader>gH` | History for the whole repo |
| `<leader>gq` | Close the diffview tab |

The plugin is [diffview-plus.nvim](https://github.com/dlyongemallo/diffview-plus.nvim),
which is a fork. Every guide points at `sindrets/diffview.nvim`, but that has
had no commits since August 2024 even though issues are still filed against it;
the fork is where fixes actually land, and it adds a directory-diff mode
(`:DiffviewDiffDirs`) that needs no repository at all.

Helix has no plugin system, so for `hx` and for the plain shell the equivalent
is **delta**, wired in as git's pager system-wide:

```sh
git diff main..feature      # two columns, n and N jump between files
```

`n` and `N` come from `delta.navigate`, which is implemented with `less`'s
search — hence `DELTA_PAGER=less` in the Dockerfile. Without it delta would
honour `$PAGER`, and if that is `moor` the navigation silently stops working.

Side-by-side is on by default, which is cramped in a narrow tmux pane. For one
invocation:

```sh
git -c delta.side-by-side=false diff main..feature
```

All of the delta settings live in `/etc/gitconfig` rather than your global
config, so `git config --global` still overrides any of them.

[TIPS.md](TIPS.md) has the rest: the full keymap tables, how to expand the
folded-away unchanged lines, and why `g?` sometimes appears to stop working.

## Volumes

Every volume below is created as `<project>_<name>`, so these are per-project
and nothing is shared between copies of the template.

| Volume | Mounted at | Contents |
|---|---|---|
| `workspace` | `/home/dev/src` | Your cloned repositories |
| `cargo-registry` | `/usr/local/cargo/registry` | Crate downloads |
| `uv-cache` | `/home/dev/.cache/uv` | Python wheel cache |
| `nvim-state` | `/home/dev/.local/state/nvim` | Undo history, shada, shell history |
| `claude-config` | `/home/dev/.claude` | Claude Code login, settings, chat history |
| `git-config` | `/home/dev/.config/git` | Global git config |

`./dev rebuild` keeps all of these. Only `./dev nuke` destroys them, and it
only destroys the current project's.

The cost of full isolation is that a new project starts cold: it re-downloads
the crate registry and Python wheels, and you log into Claude Code and set your
git identity again. If that becomes tiresome, give the cache volumes a fixed
`name:` in the template so compose stops prefixing them — but be aware that
sharing `claude-config` would also merge chat history, because Claude Code keys
history by working directory and every project's is `/home/dev/src`.

### Staying logged in to Claude Code across rebuilds

Claude Code splits its state in two. Tokens, settings and chat history go in
`~/.claude`, which the `claude-config` volume covers. Account identity and
onboarding state go in `~/.claude.json` — a single file in the home directory,
outside that volume, and so lost on every rebuild. Persisting only `~/.claude`
gets you your history back and still asks you to log in again, which is the
behaviour you would otherwise be stuck explaining to yourself every few weeks.

Docker cannot mount a volume onto a single file, so the real file lives inside
the `~/.claude` volume and `~/.claude.json` is a symlink into it, created in the
Dockerfile.

There is a known failure mode: an application that saves a file by
write-temp-then-rename does not follow a symlink, it renames over it, leaving a
plain file in the container layer that silently stops persisting. `bashrc.extra`
therefore re-checks the link on every interactive shell, and if it finds a plain
file it copies the contents onto the volume before relinking — so the login the
stray file contains survives the repair rather than being thrown away.

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

## Without the container: install-scripts/

For a dedicated machine or VM used as a remote IDE — SSH in, `tmux`, `nvim`,
with Claude Code running on the box itself — `install-scripts/install.sh`
installs the same Neovim setup directly, for the user who runs it. Ubuntu
22.04, 24.04 and 26.04, amd64 or arm64.

```
install-scripts/install.sh -l    # symlink the config to this checkout
install-scripts/install.sh -c    # copy it instead; the checkout can go
```

With neither flag it prints its help and does nothing. `-l` is the one to
use if you keep the repo on the box: a `git pull` updates the editor, and
the container and the machine can never disagree about the config.

It is the container's recipe, not a second one. The pinned versions and the
treesitter parser list are read out of the Dockerfile at run time, and the
config files are the ones in `.devcontainer/config`. What differs is where
things go: apt for system packages (through sudo when not root), everything
else under the user's home — Neovim in `~/.local/opt`, binaries in
`~/.local/bin`, Rust through rustup in `~/.cargo`, Python tooling through
uv, and a marked PATH block in `~/.profile` and `~/.bashrc`. Re-running
updates in place, and anything it replaces in `~/.config/nvim` or
`~/.tmux.conf` is kept as `<name>.bak-<timestamp>`.

Per-release differences it handles itself:

- **22.04**: the tree-sitter CLI release binaries need glibc 2.39, so it is
  built with cargo instead (a few minutes, once). fzf is too old for fzf-lua
  and git-delta is not packaged, so both come from upstream releases. The
  debug adapter is still called `lldb-vscode` there; it is linked in as
  `lldb-dap`, the name `init.lua` uses.
- **24.04, 26.04**: everything that apt has is taken from apt.

Running it with `sudo` from your own account installs for root, not for you
— it says so when that happens. Run it as the account you will work as; it
elevates for apt on its own.

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
- **`nvim-treesitter` is on `main`, not `master`.** This used to be pinned to
  `master` to keep the `configs.setup()` API and `:TSUpdateSync`. That pin
  became a bug: master's README states "Neovim 0.10 or 0.11 (Neovim 0.12 is
  **not supported**)", and on 0.12 its markdown injection query crashes the
  parser on any fenced code block — which includes every LSP hover float. The
  config now uses `main`'s `setup()`/`install()` and core Neovim's
  `vim.treesitter.start()`. See TIPS.md for the full diagnosis.
- **`incremental_selection` is gone** with the move to `main`. Neovim 0.12's own
  `an` and `in` text objects do the same job — see
  `:help treesitter-incremental-selection`.
- **Treesitter parsers need `tree-sitter-cli`,** which `main` requires and which
  the image builds with `cargo install`. Upstream is explicit that it must not
  come from npm.
- **debugpy lives in `/opt/debugpy`,** not your project venv. If your debugged
  code needs project dependencies visible to the adapter, run
  `uv pip install debugpy` inside the project venv and point
  `require("dap-python").setup(...)` at that interpreter instead.
- **Claude Code auto-updates in the background,** writing to `~/.local/bin`.
  That is not a volume, so an update is lost on rebuild and simply reapplies.
  Set `DISABLE_AUTOUPDATER=1` in the environment if you want version stability.
- **`./dev mount` changes need `./dev up`, which recreates the container.**
  Everything in the volumes survives, but the running tmux session does not.
  Adding mounts is the one routine operation here that costs you your session,
  so do it before you settle in rather than mid-afternoon.
- **`safe.directory = *` is set system-wide in the image.** It is what makes
  committing to a host repo through a bind mount work at all, but it does turn
  off a real check. Narrow it in `/etc/gitconfig` if this container ever stops
  being single-user.
- **First build takes a while** because it compiles treesitter parsers and
  downloads two toolchains. Subsequent builds hit the layer cache.
