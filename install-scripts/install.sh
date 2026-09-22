#!/usr/bin/env bash
# The Neovim setup from .devcontainer, installed on a real Ubuntu LTS machine
# (22.04, 24.04, 26.04; amd64 or arm64) for the user who runs this.
#
# Built for a dedicated box or VM used as a remote IDE: SSH in, attach tmux,
# edit in Neovim, with Claude Code running on the same machine. The container
# and this script share one config -- .devcontainer/config -- and the pinned
# versions are read from the Dockerfile's ARG lines, so the two cannot drift.
#
# System packages come from apt (through sudo unless you are root); everything
# else lands in the user's home. Safe to re-run: it updates in place.

set -euo pipefail

# Not in the Dockerfile, which gets both from apt. Used only where the release's
# own package is missing or too old (22.04: no git-delta, fzf 0.29). Pinned to
# what Ubuntu 26.04 ships, so every box ends up on the container's versions.
FZF_VERSION=0.67.0
DELTA_VERSION=0.18.2
# fzf-lua's stated requirement is "fzf > 0.36".
FZF_MIN=0.36

usage() {
  cat <<'EOF'
Usage: install-scripts/install.sh -c | -l

Install the Neovim setup from this repo for the current user, on Ubuntu
22.04, 24.04 or 26.04 (amd64 or arm64).

  -c   copy the Neovim config and tmux.conf into place: a snapshot, so the
       repo can be deleted afterwards
  -l   symlink them to this repo instead, so a git pull updates the editor
  -h   show this help

One of -c or -l is required.

Installs, for this user:
  Neovim (release tarball)    ~/.local/opt/nvim, linked from ~/.local/bin
  tree-sitter CLI             ~/.local/bin (built with cargo on 22.04)
  Rust + rust-analyzer        ~/.cargo, ~/.rustup (rustup)
  uv, basedpyright, ruff      ~/.local/bin; debugpy in ~/.local/share/nvim
  fzf, delta                  ~/.local/bin, only where apt's are missing/old
  Neovim plugins + parsers    ~/.local/share/nvim
  config                      ~/.config/nvim and ~/.tmux.conf
  PATH                        a marked block in ~/.profile and ~/.bashrc

and system-wide through apt: build tools, git, curl, ripgrep, fd-find,
tmux, lldb, and fzf/git-delta where the release's versions are usable.

Anything this replaces in ~/.config/nvim or ~/.tmux.conf is kept alongside
as <name>.bak-<timestamp>. Safe to re-run.
EOF
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
MODE=""
while getopts ":clh" opt; do
  case "$opt" in
    c) [ -z "$MODE" ] || die "-c and -l are mutually exclusive"; MODE="copy" ;;
    l) [ -z "$MODE" ] || die "-c and -l are mutually exclusive"; MODE="link" ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || { usage >&2; exit 2; }
if [ -z "$MODE" ]; then usage; exit 0; fi

# ---------------------------------------------------------------------------
# Where things are
# ---------------------------------------------------------------------------
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DC="$REPO/.devcontainer"
[ -f "$DC/Dockerfile" ] || die "no $DC/Dockerfile: run this from a checkout of the repo"

# Install for the user running the script, with their home taken from the
# password database rather than trusted from $HOME.
TARGET_USER="$(id -un)"
HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
  die "cannot find a home directory for $TARGET_USER"
fi
export HOME

BIN="$HOME/.local/bin"
OPT="$HOME/.local/opt"
NVIM_DATA="$HOME/.local/share/nvim"
export PATH="$BIN:$HOME/.cargo/bin:$PATH"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Versions: the Dockerfile is the single source of truth
# ---------------------------------------------------------------------------
dockerfile_arg() {
  local v
  v="$(sed -n "s/^ARG $1=//p" "$DC/Dockerfile" | head -n1 | tr -d '[:space:]')"
  [ -n "$v" ] || die "ARG $1 not found in $DC/Dockerfile"
  printf '%s\n' "$v"
}
NVIM_VERSION="$(dockerfile_arg NVIM_VERSION)"
TREE_SITTER_VERSION="$(dockerfile_arg TREE_SITTER_VERSION)"
PYTHON_VERSION="$(dockerfile_arg PYTHON_VERSION)"
RUST_TOOLCHAIN="$(dockerfile_arg RUST_TOOLCHAIN)"

# The parser list comes from the Dockerfile's bake step, the one line that
# names them, so adding a language there adds it here.
PARSERS="$(sed -n "s/.*require('nvim-treesitter')\.install({ *\(.*[^ ]\) *}).*/\1/p" "$DC/Dockerfile" | head -n1)"
[ -n "$PARSERS" ] || die "could not find the treesitter parser list in $DC/Dockerfile"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  local id version
  # shellcheck source=/dev/null
  id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  # shellcheck source=/dev/null
  version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
  [ "$id" = ubuntu ] || die "Ubuntu only (this is ${id:-unknown})"
  case "$version" in
    22.04 | 24.04 | 26.04) ;;
    *)
      dpkg --compare-versions "$version" ge 22.04 \
        || die "Ubuntu 22.04 or later required (this is $version)"
      warn "Ubuntu $version has not been tried; tested releases are 22.04, 24.04 and 26.04"
      ;;
  esac
  UBUNTU_VERSION="$version"

  case "$(dpkg --print-architecture)" in
    amd64 | arm64) ARCH="$(dpkg --print-architecture)" ;;
    *) die "amd64 or arm64 only" ;;
  esac

  if [ "$(id -u)" -eq 0 ]; then
    SUDO=()
  else
    command -v sudo >/dev/null || die "apt needs root: run as root, or install sudo"
    SUDO=(sudo)
  fi

  # `sudo ./install.sh` from your own account installs for root, which is
  # correct when root is who you work as (the Claude-Code-as-root case) and a
  # surprise otherwise. Say which.
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "$TARGET_USER" ]; then
    warn "running under sudo, so this installs for $TARGET_USER, not $SUDO_USER." \
      "To set up $SUDO_USER, run it as $SUDO_USER without sudo; it asks for sudo itself."
  fi

  step "Installing for $TARGET_USER ($HOME) on Ubuntu $UBUNTU_VERSION $ARCH, mode: $MODE"
  note "neovim $NVIM_VERSION, tree-sitter $TREE_SITTER_VERSION, python $PYTHON_VERSION, rust $RUST_TOOLCHAIN"
}

fetch() {
  curl -fsSL --retry 3 -o "$2" "$1" || die "download failed: $1"
}

apt_candidate() {
  apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ { print $2 }'
}

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
USE_APT_FZF=0
USE_APT_DELTA=0

install_apt() {
  step "System packages (apt)"
  "${SUDO[@]}" apt-get update

  # build-essential: tree-sitter compiles every parser with the system cc, and
  # Rust links with it. ncurses-term: the tmux-256color terminfo our tmux.conf
  # asks for. lldb: provides the debug adapter nvim-dap uses for Rust.
  local pkgs=(
    build-essential pkg-config libssl-dev
    ca-certificates curl git unzip xz-utils gzip
    ripgrep fd-find less
    tmux ncurses-term
    lldb
  )

  local c
  c="$(apt_candidate fzf)"
  if [ -n "$c" ] && [ "$c" != "(none)" ] && dpkg --compare-versions "$c" gt "$FZF_MIN"; then
    pkgs+=(fzf)
    USE_APT_FZF=1
  fi
  c="$(apt_candidate git-delta)"
  if [ -n "$c" ] && [ "$c" != "(none)" ]; then
    pkgs+=(git-delta)
    USE_APT_DELTA=1
  fi

  # env, not a prefix assignment: sudo would drop DEBIAN_FRONTEND otherwise.
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends "${pkgs[@]}"
}

# ---------------------------------------------------------------------------
# Neovim
#
# The release tarball, as in the container: every LTS here packages an older
# minor version than the plugin stack targets. It needs glibc 2.34, which
# 22.04 has.
# ---------------------------------------------------------------------------
install_nvim() {
  step "Neovim ($NVIM_VERSION)"
  local a
  case "$ARCH" in amd64) a=x86_64 ;; arm64) a=arm64 ;; esac
  fetch "https://github.com/neovim/neovim/releases/download/$NVIM_VERSION/nvim-linux-$a.tar.gz" \
    "$TMP/nvim.tar.gz"
  mkdir -p "$OPT" "$BIN"
  rm -rf "$OPT/nvim.new"
  mkdir -p "$OPT/nvim.new"
  tar -xzf "$TMP/nvim.tar.gz" -C "$OPT/nvim.new" --strip-components=1
  rm -rf "$OPT/nvim"
  mv "$OPT/nvim.new" "$OPT/nvim"
  ln -sfn "$OPT/nvim/bin/nvim" "$BIN/nvim"
  note "$("$BIN/nvim" --version | head -n1)"
}

# ---------------------------------------------------------------------------
# Rust
#
# Before tree-sitter, because on 22.04 the tree-sitter CLI is built with cargo.
# --no-modify-path: the PATH block written below covers ~/.cargo/bin.
# ---------------------------------------------------------------------------
install_rust() {
  step "Rust ($RUST_TOOLCHAIN) with rust-analyzer"
  local comps=(-c rust-analyzer -c clippy -c rustfmt -c rust-src)
  if command -v rustup >/dev/null; then
    rustup toolchain install "$RUST_TOOLCHAIN" "${comps[@]}"
    # Only when there is no default yet: someone who already runs, say,
    # nightly by default has chosen that.
    if ! rustup default >/dev/null 2>&1; then
      rustup default "$RUST_TOOLCHAIN"
    fi
  else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --default-toolchain "$RUST_TOOLCHAIN" "${comps[@]}"
  fi
  note "$(rustc --version)"
  note "$(rust-analyzer --version)"
}

# ---------------------------------------------------------------------------
# tree-sitter CLI
#
# nvim-treesitter's `main` branch shells out to it to build every parser, and
# needs 0.26.1 or later. Every 0.26.x release binary is linked against glibc
# 2.39: fine on 24.04 and 26.04, but 22.04 has 2.35 and the binary will not
# start. So: try the release binary, and build from source if it will not run,
# rather than keeping a table of which release needs which.
#
# The source build drops default features. The one it loses, qjs-rt, embeds a
# JavaScript engine so `tree-sitter generate` can evaluate grammar.js without
# Node; it is also what needs libclang to build, which is what broke the
# container build when it used `cargo install`. nvim-treesitter generates from
# grammar.json, which needs no JavaScript, and none of our parsers generate
# at all.
# ---------------------------------------------------------------------------
tree_sitter_version() {
  "$1" --version 2>/dev/null | awk '{ print $2 }'
}

install_tree_sitter() {
  step "tree-sitter CLI ($TREE_SITTER_VERSION)"
  if [ -x "$BIN/tree-sitter" ] && [ "$(tree_sitter_version "$BIN/tree-sitter")" = "$TREE_SITTER_VERSION" ]; then
    note "already installed"
    return
  fi

  local a
  case "$ARCH" in amd64) a=x64 ;; arm64) a=arm64 ;; esac
  fetch "https://github.com/tree-sitter/tree-sitter/releases/download/v$TREE_SITTER_VERSION/tree-sitter-linux-$a.gz" \
    "$TMP/tree-sitter.gz"
  gunzip -c "$TMP/tree-sitter.gz" > "$TMP/tree-sitter"
  chmod 0755 "$TMP/tree-sitter"

  if "$TMP/tree-sitter" --version >/dev/null 2>&1; then
    rm -f "$BIN/tree-sitter"
    mv "$TMP/tree-sitter" "$BIN/tree-sitter"
  else
    note "the release binary does not run here (it needs glibc 2.39); building with cargo"
    note "this takes a few minutes"
    cargo install --locked --no-default-features \
      --root "$OPT/tree-sitter" "tree-sitter-cli@$TREE_SITTER_VERSION"
    ln -sfn "$OPT/tree-sitter/bin/tree-sitter" "$BIN/tree-sitter"
  fi
  note "$("$BIN/tree-sitter" --version)"
}

# ---------------------------------------------------------------------------
# fzf, delta, fd
# ---------------------------------------------------------------------------
install_cli_tools() {
  step "fzf, delta, fd"

  # Ubuntu ships fd as `fdfind`, clashing with an older package's name.
  ln -sfn "$(command -v fdfind)" "$BIN/fd"
  note "fd -> $(command -v fdfind)"

  if [ "$USE_APT_FZF" = 1 ]; then
    note "fzf $(fzf --version | awk '{ print $1 }') (apt)"
  elif [ -x "$BIN/fzf" ] && [ "$("$BIN/fzf" --version | awk '{ print $1 }')" = "$FZF_VERSION" ]; then
    note "fzf $FZF_VERSION already installed"
  else
    local fa
    case "$ARCH" in amd64) fa=linux_amd64 ;; arm64) fa=linux_arm64 ;; esac
    fetch "https://github.com/junegunn/fzf/releases/download/v$FZF_VERSION/fzf-$FZF_VERSION-$fa.tar.gz" \
      "$TMP/fzf.tar.gz"
    tar -xzf "$TMP/fzf.tar.gz" -C "$TMP" fzf
    install -m 0755 "$TMP/fzf" "$BIN/fzf"
    note "fzf $FZF_VERSION (upstream; apt's is older than fzf-lua needs)"
  fi

  if [ "$USE_APT_DELTA" = 1 ]; then
    note "delta $(delta --version | awk '{ print $2 }') (apt)"
  elif [ -x "$BIN/delta" ] && [ "$("$BIN/delta" --version | awk '{ print $2 }')" = "$DELTA_VERSION" ]; then
    note "delta $DELTA_VERSION already installed"
  else
    # musl on amd64 for a static binary; there is no musl build for arm64,
    # and the gnu one needs only glibc 2.18.
    local target
    case "$ARCH" in
      amd64) target=x86_64-unknown-linux-musl ;;
      arm64) target=aarch64-unknown-linux-gnu ;;
    esac
    fetch "https://github.com/dandavison/delta/releases/download/$DELTA_VERSION/delta-$DELTA_VERSION-$target.tar.gz" \
      "$TMP/delta.tar.gz"
    tar -xzf "$TMP/delta.tar.gz" -C "$TMP"
    install -m 0755 "$TMP/delta-$DELTA_VERSION-$target/delta" "$BIN/delta"
    note "delta $DELTA_VERSION (upstream; this release does not package it)"
  fi
}

# ---------------------------------------------------------------------------
# Python tooling
#
# uv provides the interpreter, so the release's own Python version does not
# matter (22.04 has 3.10). basedpyright's PyPI package bundles its own Node, so
# no Node install is needed for it either.
# ---------------------------------------------------------------------------
install_python_tools() {
  step "Python tooling via uv (Python $PYTHON_VERSION)"
  if [ -x "$BIN/uv" ]; then
    note "uv already installed"
  else
    curl -LsSf https://astral.sh/uv/install.sh \
      | env UV_INSTALL_DIR="$BIN" UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh
  fi

  uv python install "$PYTHON_VERSION"
  uv tool install --upgrade --python "$PYTHON_VERSION" basedpyright
  uv tool install --upgrade --python "$PYTHON_VERSION" ruff

  # init.lua looks here when the container's /opt/debugpy is absent.
  local venv="$NVIM_DATA/debugpy"
  if [ ! -x "$venv/bin/python" ]; then
    rm -rf "$venv"
    uv venv "$venv" --python "$PYTHON_VERSION"
  fi
  uv pip install --python "$venv/bin/python" --upgrade debugpy
  note "debugpy in $venv"
}

# ---------------------------------------------------------------------------
# lldb-dap
#
# init.lua runs `lldb-dap`. The adapter was called lldb-vscode until LLVM 18,
# and is versioned on some releases: 22.04 ships lldb-vscode-14, 24.04
# lldb-dap-18, 26.04 an unversioned lldb-dap. Same adapter, same protocol, so
# link whichever is here under the name the config uses.
# ---------------------------------------------------------------------------
link_lldb_dap() {
  step "lldb-dap (Rust debugging)"
  local c dap=""
  for c in /usr/bin/lldb-dap /usr/bin/lldb-dap-* /usr/lib/llvm-*/bin/lldb-dap \
           /usr/bin/lldb-vscode /usr/bin/lldb-vscode-* /usr/lib/llvm-*/bin/lldb-vscode; do
    if [ -x "$c" ]; then dap="$c"; break; fi
  done
  if [ -n "$dap" ]; then
    ln -sfn "$dap" "$BIN/lldb-dap"
    note "lldb-dap -> $dap"
  else
    warn "no lldb-dap or lldb-vscode found; Rust debugging will not work"
  fi
}

# ---------------------------------------------------------------------------
# PATH
#
# Ubuntu's stock ~/.profile adds ~/.local/bin, but only if it existed at login,
# and root's does not add it at all; nothing adds ~/.cargo/bin. A marked block
# in ~/.profile covers login shells (SSH, tmux panes), and the same block in
# ~/.bashrc covers interactive shells started some other way. The guards make
# the two harmless together. Re-running replaces the block rather than adding
# another.
# ---------------------------------------------------------------------------
BLOCK_BEGIN='# >>> idecontainer install-scripts >>>'
BLOCK_END='# <<< idecontainer install-scripts <<<'

path_block() {
  cat <<EOF
$BLOCK_BEGIN
# Written by install-scripts/install.sh; re-running it rewrites this block.
case ":\$PATH:" in *":\$HOME/.local/bin:"*) ;; *) PATH="\$HOME/.local/bin:\$PATH" ;; esac
case ":\$PATH:" in *":\$HOME/.cargo/bin:"*) ;; *) PATH="\$HOME/.cargo/bin:\$PATH" ;; esac
export PATH
$BLOCK_END
EOF
}

write_path_block() {
  local f="$1"
  touch "$f"
  # --follow-symlinks: dotfiles are often links into a dotfiles repo, and a
  # plain -i would replace the link with a regular file.
  sed -i --follow-symlinks "\|^$BLOCK_BEGIN\$|,\|^$BLOCK_END\$|d" "$f"
  # One blank line before the block, not one more per re-run.
  if [ -n "$(tail -n1 "$f")" ]; then printf '\n' >> "$f"; fi
  printf '%s\n' "$(path_block)" >> "$f"
  note "PATH block in $f"
}

setup_shell() {
  step "Shell PATH"
  write_path_block "$HOME/.profile"
  # A login bash reads only the first of ~/.bash_profile, ~/.bash_login and
  # ~/.profile that exists, so if either of the others is there, it gets the
  # block too.
  local f
  for f in "$HOME/.bash_profile" "$HOME/.bash_login"; do
    if [ -f "$f" ]; then write_path_block "$f"; fi
  done
  write_path_block "$HOME/.bashrc"
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# place SRC DEST: copy or link SRC to DEST according to -c/-l, setting aside
# whatever was at DEST first. Does nothing if DEST is already what it would be.
place() {
  local src="$1" dest="$2" bak
  if [ "$MODE" = link ]; then
    if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ]; then
      note "$dest already links to the repo"
      return
    fi
  elif [ -e "$dest" ] && [ ! -L "$dest" ] && diff -rq "$src" "$dest" >/dev/null 2>&1; then
    note "$dest already up to date"
    return
  fi

  if [ -e "$dest" ] || [ -L "$dest" ]; then
    bak="$dest.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$dest" "$bak"
    note "kept the previous $dest as $bak"
  fi
  mkdir -p "$(dirname "$dest")"
  if [ "$MODE" = link ]; then
    ln -s "$src" "$dest"
    note "$dest -> $src"
  else
    cp -a "$src" "$dest"
    note "copied to $dest"
  fi
}

install_config() {
  step "Config ($MODE)"
  if [ "$MODE" = link ]; then
    # devtips.lua finds TIPS.md at the repo root through this link.
    place "$DC/config/nvim" "$HOME/.config/nvim"
  else
    # In the container TIPS.md is bind-mounted into the config dir; a copy
    # carries its own. Assembled first so the up-to-date check compares like
    # with like.
    cp -a "$DC/config/nvim" "$TMP/nvim"
    cp "$REPO/TIPS.md" "$TMP/nvim/TIPS.md"
    place "$TMP/nvim" "$HOME/.config/nvim"
  fi
  place "$DC/config/tmux.conf" "$HOME/.tmux.conf"
}

# ---------------------------------------------------------------------------
# Plugins and parsers
#
# The same two steps the Dockerfile bakes in. nvim-treesitter's install():wait()
# reports success even when every download failed, hence the count.
# ---------------------------------------------------------------------------
install_plugins() {
  step "Neovim plugins"
  "$BIN/nvim" --headless "+Lazy! sync" +qa

  step "Treesitter parsers"
  "$BIN/nvim" --headless \
    "+lua require('nvim-treesitter').install({ $PARSERS }):wait(300000)" +qa

  local want have
  want="$(printf '%s\n' "$PARSERS" | tr ',' '\n' | grep -c .)"
  have="$(find "$NVIM_DATA/site/parser" -name '*.so' 2>/dev/null | wc -l)"
  if [ "$have" -ge "$want" ]; then
    note "$have parsers installed"
  else
    warn "expected $want treesitter parsers, found $have. Run :TSUpdate inside nvim to retry."
  fi
}

summary() {
  step "Done"
  note "Start a new login shell (or run: . ~/.profile) to pick up PATH, then:"
  note "  tmux new -A -s ide     # survives SSH disconnects"
  note "  nvim .                 # file tree on the left; :Tips for the reference"
  note "Health check inside nvim: :checkhealth vim.lsp nvim-treesitter"
}

main() {
  preflight
  install_apt
  install_nvim
  install_rust
  install_tree_sitter
  install_cli_tools
  install_python_tools
  link_lldb_dap
  setup_shell
  install_config
  install_plugins
  summary
}

main
