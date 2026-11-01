#!/usr/bin/env bash
# The Neovim setup from .devcontainer, installed on a real Ubuntu LTS machine
# (22.04, 24.04, 26.04; amd64 or arm64) or a Mac (Apple silicon or Intel) for
# the user who runs this.
#
# Built for a dedicated box or VM used as a remote IDE: SSH in, attach tmux,
# edit in Neovim, with Claude Code running on the same machine. The container
# and this script share one config -- .devcontainer/config -- and the pinned
# versions are read from the Dockerfile's ARG lines, so the two cannot drift.
#
# System packages come from apt (through sudo unless you are root), or on
# macOS from Homebrew; everything else lands in the user's home. Safe to
# re-run: it updates in place.
#
# Meant to run on macOS's own bash 3.2 as well as on a newer one, so on that
# path: no empty arrays under `set -u` (3.2 calls them unbound), and no
# GNU-only tools or flags (getent, `sed -i`). `readlink -f` is fine: macOS has
# had it since 12.3, and Homebrew wants a newer macOS than that anyway.

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
22.04, 24.04 or 26.04 (amd64 or arm64), or on macOS with Homebrew.

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
  PATH                        a marked block in ~/.profile and ~/.bashrc,
                              and ~/.zprofile and ~/.zshrc if you use zsh

and system-wide through apt: build tools, git, curl, ripgrep, fd-find,
tmux, lldb, and fzf/git-delta where the release's versions are usable.

On macOS, Homebrew instead of apt: ripgrep, fd, fzf, git-delta, tmux and
ncurses. It needs Homebrew and the Xcode Command Line Tools already there
(the compiler, git and lldb come from those), and adds the tmux-256color
terminfo entry to ~/.terminfo, which macOS lacks.

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

OS="$(uname -s)"
case "$OS" in
  Linux | Darwin) ;;
  *) die "Ubuntu or macOS only (this is $OS)" ;;
esac

# The user's home from the account database. macOS keeps accounts in
# Directory Services and has no getent; dscl prints `NFSHomeDirectory: /path`,
# or the value on a second line, indented, when it contains a space.
home_of() {
  if [ "$OS" = Darwin ]; then
    dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null \
      | sed -e '1s/^NFSHomeDirectory:[[:space:]]*//' -e 's/^[[:space:]]*//' | tr -d '\n'
  else
    getent passwd "$1" | cut -d: -f6
  fi
}

# Install for the user running the script, with their home taken from the
# account database rather than trusted from $HOME.
TARGET_USER="$(id -un)"
# `|| true` so that a failed lookup reaches the message below, rather than
# ending the script silently under `set -e`.
HOME="$(home_of "$TARGET_USER" || true)"
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
  if [ "$OS" = Darwin ]; then preflight_macos; else preflight_ubuntu; fi
  step "Installing for $TARGET_USER ($HOME) on $PLATFORM $ARCH, mode: $MODE"
  note "neovim $NVIM_VERSION, tree-sitter $TREE_SITTER_VERSION, python $PYTHON_VERSION, rust $RUST_TOOLCHAIN"
}

preflight_macos() {
  PLATFORM="macOS $(sw_vers -productVersion)"
  # The OS part of the Neovim and tree-sitter release asset names.
  RELEASE_OS=macos
  # ARCH keeps Debian's names on both systems, so that every download step
  # maps it the same way whatever the OS.
  case "$(uname -m)" in
    arm64) ARCH=arm64 ;;
    x86_64) ARCH=amd64 ;;
    *) die "Apple silicon or Intel only (this is $(uname -m))" ;;
  esac
  # A shell under Rosetta reports x86_64 on Apple silicon, and would get
  # Intel builds of everything here: they work, translated, and slower.
  if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null)" = 1 ]; then
    warn "this shell runs under Rosetta, so Intel builds will be installed." \
      "Run it from a native arm64 shell for Apple silicon builds."
  fi
  # Homebrew refuses to run as root, and there is no sudo step to fall back on.
  [ "$(id -u)" -ne 0 ] || die "run this as your own account, not root: Homebrew refuses root"
  command -v brew >/dev/null || die "Homebrew is required (https://brew.sh), with brew on PATH"
  # The C compiler for the treesitter parsers, git, and lldb-dap. Installing
  # them is a GUI dialog, so ask for it rather than start it.
  xcode-select -p >/dev/null 2>&1 \
    || die "the Xcode Command Line Tools are required: run xcode-select --install, then this again"
}

preflight_ubuntu() {
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
  PLATFORM="Ubuntu $version"
  RELEASE_OS=linux

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

# The apt list's counterparts. The Command Line Tools (checked in preflight)
# cover build-essential, git and lldb, and macOS has curl, unzip and gzip, and
# a tar that handles xz itself. Homebrew's fzf and git-delta are current, so
# no version test. ncurses is for its terminfo: see setup_terminfo_macos.
# `brew install` also upgrades anything already installed but outdated.
install_brew() {
  step "System packages (Homebrew)"
  brew install ripgrep fd fzf git-delta tmux ncurses
}

# ---------------------------------------------------------------------------
# tmux-256color on macOS
#
# tmux.conf sets default-terminal to tmux-256color, and macOS's own ncurses is
# 5.7 from 2008, which does not know that entry: programs in a tmux pane then
# complain ("WARNING: terminal is not fully functional" from less). On Ubuntu
# it comes from ncurses-term. Here it is exported from Homebrew's ncurses and
# compiled into ~/.terminfo with the *system* tic, which writes the database
# layout the system ncurses reads. Homebrew's tic would write one it cannot.
# ---------------------------------------------------------------------------
setup_terminfo_macos() {
  step "tmux-256color terminfo"
  if /usr/bin/infocmp tmux-256color >/dev/null 2>&1; then
    note "already known to the system ncurses"
    return
  fi
  local brew_infocmp
  brew_infocmp="$(brew --prefix ncurses)/bin/infocmp"
  if [ -x "$brew_infocmp" ] \
    && "$brew_infocmp" -x tmux-256color > "$TMP/tmux-256color.info" \
    && /usr/bin/tic -x -o "$HOME/.terminfo" "$TMP/tmux-256color.info"; then
    note "compiled into ~/.terminfo"
  else
    warn "could not add tmux-256color to ~/.terminfo; programs inside tmux may say the" \
      "terminal is not fully functional"
  fi
}

# ---------------------------------------------------------------------------
# Neovim
#
# The release tarball, as in the container: every LTS here packages an older
# minor version than the plugin stack targets. It needs glibc 2.34, which
# 22.04 has. The macOS tarball has the same layout. Downloaded with curl it
# carries no quarantine attribute, so Gatekeeper does not stop it, which it
# would after a browser download.
# ---------------------------------------------------------------------------
install_nvim() {
  step "Neovim ($NVIM_VERSION)"
  local a
  case "$ARCH" in amd64) a=x86_64 ;; arm64) a=arm64 ;; esac
  fetch "https://github.com/neovim/neovim/releases/download/$NVIM_VERSION/nvim-$RELEASE_OS-$a.tar.gz" \
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
  fetch "https://github.com/tree-sitter/tree-sitter/releases/download/v$TREE_SITTER_VERSION/tree-sitter-$RELEASE_OS-$a.gz" \
    "$TMP/tree-sitter.gz"
  gunzip -c "$TMP/tree-sitter.gz" > "$TMP/tree-sitter"
  chmod 0755 "$TMP/tree-sitter"

  if "$TMP/tree-sitter" --version >/dev/null 2>&1; then
    rm -f "$BIN/tree-sitter"
    mv "$TMP/tree-sitter" "$BIN/tree-sitter"
  else
    note "the release binary does not run here (on Ubuntu 22.04: it needs glibc 2.39); building with cargo"
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

  if [ "$OS" = Darwin ]; then
    note "fd $(fd --version | awk '{ print $2 }'), fzf $(fzf --version | awk '{ print $1 }')," \
      "delta $(delta --version | awk '{ print $2 }') (Homebrew)"
    return
  fi

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
  if [ "$OS" = Darwin ]; then link_lldb_dap_macos; return; fi
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

# Xcode 16 and later ship lldb-dap, which `xcrun` finds whether it comes from
# the Command Line Tools or Xcode.app; Homebrew's llvm has one too. A wrapper
# script rather than a link, so that it goes through `xcrun`: that follows
# `xcode-select` and survives an Xcode update moving the binary, where a link
# to today's path would break.
link_lldb_dap_macos() {
  local run=""
  if xcrun -f lldb-dap >/dev/null 2>&1; then
    run='exec xcrun lldb-dap "$@"'
    note "lldb-dap -> $(xcrun -f lldb-dap), through xcrun"
  elif [ -x "$(brew --prefix llvm)/bin/lldb-dap" ]; then
    run="exec '$(brew --prefix llvm)/bin/lldb-dap' \"\$@\""
    note "lldb-dap -> $(brew --prefix llvm)/bin/lldb-dap"
  else
    warn "no lldb-dap: it comes with Xcode 16 or later, or brew install llvm;" \
      "Rust debugging will not work"
    return
  fi
  # rm first: writing through a link left by an earlier run would overwrite
  # whatever it points at.
  rm -f "$BIN/lldb-dap"
  printf '#!/bin/sh\n%s\n' "$run" > "$BIN/lldb-dap"
  chmod 0755 "$BIN/lldb-dap"
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
#
# zsh reads none of those, and is the default shell on macOS. It gets the same
# block in ~/.zprofile (login shells, which is what Terminal, iTerm2 and tmux
# start) and ~/.zshrc. That is done when zsh is the login shell or already has
# either file, so a bash user does not grow zsh dotfiles. On macOS
# /etc/zprofile runs path_helper, which reorders PATH, before ~/.zprofile, so
# the block there still comes out in front. fish is left to you.
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
  local f="$1" new="$TMP/rc"
  touch "$f"
  # The file without any earlier block, by awk rather than `sed -i`, whose
  # syntax differs between GNU and BSD sed. Written back with `cat >`, which
  # writes through a symlink: dotfiles are often links into a dotfiles repo,
  # and replacing the file would turn the link into a regular file.
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" \
    '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' "$f" > "$new"
  # One blank line before the block, not one more per re-run.
  if [ -n "$(tail -n1 "$new")" ]; then printf '\n' >> "$new"; fi
  path_block >> "$new"
  cat "$new" > "$f"
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

  if [ "$(basename "${SHELL:-}")" = zsh ] || [ -f "$HOME/.zprofile" ] || [ -f "$HOME/.zshrc" ]; then
    write_path_block "$HOME/.zprofile"
    write_path_block "$HOME/.zshrc"
  fi
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
  # tr: BSD wc pads the count with spaces.
  have="$(find "$NVIM_DATA/site/parser" -name '*.so' 2>/dev/null | wc -l | tr -d '[:space:]')"
  if [ "$have" -ge "$want" ]; then
    note "$have parsers installed"
  else
    warn "expected $want treesitter parsers, found $have. Run :TSUpdate inside nvim to retry."
  fi
}

# ---------------------------------------------------------------------------
# What a new terminal will find
#
# Neovim finds its language servers on its own PATH, and Nvim 0.12 skips a
# server it cannot find without saying so: completion just falls back to words
# from the buffer. So, last, list every match of each tool the editor needs, as
# `which -a` would, on the PATH a new terminal will have. That is not this
# script's PATH, which has ~/.local/bin and ~/.cargo/bin added at the top and
# would hide exactly the problem being checked for. Instead a login shell of
# the user's own $SHELL is started from a bare environment and asked for its
# PATH. Anything that shell prints on stderr is shown too: a broken line in a
# startup file, such as a `. "$HOME/.cargo/env"` left behind by an earlier
# rustup whose ~/.cargo has gone, greets every new terminal the same way.
#
# Rust gets one more check. rustc, cargo and rust-analyzer should be rustup's
# proxies, from the directory of the first rustup. With Homebrew's `rust`
# formula installed, /opt/homebrew/bin/rustc can come first instead. Then
# rust-analyzer (rustup's) and cargo (Homebrew's) are two different Rusts.
# ---------------------------------------------------------------------------
CHECK_TOOLS="nvim basedpyright-langserver ruff rustup rustc cargo rust-analyzer"

# The PATH of a new login shell, or nothing if it could not be read. The marker
# line keeps it apart from anything the startup files print on stdout.
login_path() {
  local sh="${SHELL:-/bin/sh}"
  env -i HOME="$HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" SHELL="$sh" \
    TERM="${TERM:-dumb}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$sh" -lc 'printf "\n__PATH__=%s\n" "$PATH"' </dev/null 2>"$TMP/login.err" \
    | sed -n 's/^__PATH__=//p' | tail -n1
}

# which_all TOOL PATH: every executable TOOL along PATH, in order, once each.
which_all() {
  local IFS=: d seen=":"
  for d in $2; do
    if [ -n "$d" ] && [ -x "$d/$1" ] && [ ! -d "$d/$1" ]; then
      case "$seen" in *":$d:"*) continue ;; esac
      seen="$seen$d:"
      printf '%s\n' "$d/$1"
    fi
  done
  return 0
}

# What to do about a tool a new terminal will not find.
missing_hint() {
  local here
  here="$(command -v "$1" || true)"
  if [ -n "$here" ]; then
    printf '%s' "It is installed, at $here, but a new terminal's PATH lacks $(dirname "$here"): add that to your shell's startup file."
    return
  fi
  case "$1" in
    nvim) printf '%s' "Re-run this script." ;;
    basedpyright-langserver) printf '%s' "Install it: uv tool install basedpyright" ;;
    ruff) printf '%s' "Install it: uv tool install ruff" ;;
    rustup) printf '%s' "Re-run this script: with no rustup on PATH it installs the official one into ~/.cargo." ;;
    rust-analyzer) printf '%s' "Install it: rustup component add rust-analyzer" ;;
    *) printf '%s' "Install a toolchain: rustup default $RUST_TOOLCHAIN" ;;
  esac
}

check_tools() {
  step "What a new terminal will find"
  local lpath sh_name
  sh_name="$(basename "${SHELL:-sh}")"
  lpath="$(login_path || true)"
  if [ -s "$TMP/login.err" ]; then
    warn "starting a new login $sh_name printed errors, which every new terminal will show too:"
    sed 's/^/      /' "$TMP/login.err" >&2
  fi
  if [ -z "$lpath" ]; then
    warn "could not read the PATH of a new login $sh_name; checking this script's PATH instead"
    lpath="$PATH"
  else
    note "on the PATH of a new login $sh_name:"
  fi

  local t hits first rustup_dir="" problems=0
  for t in $CHECK_TOOLS; do
    hits="$(which_all "$t" "$lpath")"
    if [ -z "$hits" ]; then
      printf '    %-24s %s\n' "$t" "(not found)"
      warn "$t: not found. $(missing_hint "$t")"
      problems=1
      continue
    fi
    # Like `which -a`: the first is the one that runs.
    printf '%s\n' "$hits" | awk -v t="$t" \
      'NR == 1 { printf "    %-24s %s\n", t, $0; next } { printf "    %-24s %s  (not used)\n", "", $0 }'
    first="$(printf '%s\n' "$hits" | head -n1)"
    case "$t" in
      rustup) rustup_dir="$(dirname "$first")" ;;
      rustc | cargo | rust-analyzer)
        if [ -n "$rustup_dir" ] && [ "$(dirname "$first")" != "$rustup_dir" ]; then
          warn "$t: $first comes before rustup's, so it is not rustup's toolchain that runs." \
            "Put $rustup_dir earlier on PATH, or remove the other Rust (brew uninstall rust)."
          problems=1
        fi
        ;;
    esac
    # rustup installs the rust-analyzer proxy even without the component,
    # and the proxy then fails with "Unknown binary 'rust-analyzer'".
    if [ "$t" = rust-analyzer ] && ! env PATH="$lpath" "$first" --version >/dev/null 2>&1; then
      warn "rust-analyzer: $first does not run. Install it: rustup component add rust-analyzer"
      problems=1
    fi
  done
  if [ "$problems" = 1 ]; then
    warn "Neovim skips a language server it cannot find; :LspStatus inside nvim says which."
  fi
}

summary() {
  step "Done"
  note "Start a new login shell (or run: . ~/.profile, or . ~/.zprofile in zsh) to pick up PATH, then:"
  note "  tmux new -A -s ide     # survives SSH disconnects"
  note "  nvim .                 # file tree on the left; :Tips for the reference"
  note "Health check inside nvim: :checkhealth vim.lsp nvim-treesitter"
}

main() {
  preflight
  if [ "$OS" = Darwin ]; then
    install_brew
    setup_terminfo_macos
  else
    install_apt
  fi
  install_nvim
  install_rust
  install_tree_sitter
  install_cli_tools
  install_python_tools
  link_lldb_dap
  setup_shell
  install_config
  install_plugins
  check_tools
  summary
}

main
