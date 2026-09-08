# syntax=docker/dockerfile:1
#
# Polyglot terminal dev container: Helix + evil-helix + Neovim, Python + Rust,
# Claude Code. Designed to be lived in via tmux, so a host suspend never breaks
# your session.
#
# 26.04 LTS notes worth knowing when something builds oddly: sudo is now
# sudo-rs, and the core utilities come from rust-coreutils (cp, mv and rm are
# still GNU). Both are close enough to drop-in, but this file's ln, chmod and
# ls now run through uutils implementations.

FROM ubuntu:26.04

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

# Pinned so rebuilds are reproducible. Bump deliberately.
ARG HELIX_VERSION=25.07.1
# evil-helix tags releases on demand rather than on a cadence; this is the
# newest as of 2026-09. Check for a newer tag before assuming it is stale.
ARG EVIL_HELIX_VERSION=release-20250915
ARG NVIM_VERSION=stable
ARG NODE_MAJOR=22
ARG PYTHON_VERSION=3.12
ARG RUST_TOOLCHAIN=stable

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ---------------------------------------------------------------------------
# Base system packages
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential pkg-config libssl-dev \
        ca-certificates curl wget gnupg \
        git git-lfs openssh-client \
        tmux ripgrep fd-find fzf jq tree less \
        unzip zip xz-utils \
        lldb \
        python3 python3-venv \
        sudo locales man-db procps \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# The DAP binary moved from lldb-vscode to lldb-dap in LLVM 18. On 26.04 the
# lldb package (LLVM 21) ships an unversioned /usr/bin/lldb-dap, but older and
# newer releases version it, so keep discovering it rather than hardcoding.
RUN set -eux; \
    dap="$(ls /usr/bin/lldb-dap* /usr/lib/llvm-*/bin/lldb-dap 2>/dev/null | head -n1 || true)"; \
    if [ -n "$dap" ]; then \
        ln -sf "$dap" /usr/local/bin/lldb-dap; \
        echo "lldb-dap -> $dap"; \
    else \
        echo "WARNING: no lldb-dap found; Rust debugging will not work"; \
    fi

# Node is not needed by Claude Code itself (the native installer ships a
# self-contained binary), but npx-based MCP servers and some tooling want it.
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Non-root user
#
# Ubuntu images since 24.04 ship a stock 'ubuntu' account already occupying
# UID 1000, which collides with the typical host UID. Remove whoever holds the
# UID before creating ours, so this keeps working across base image bumps.
# ---------------------------------------------------------------------------
RUN set -eux; \
    if getent passwd "${USER_UID}" >/dev/null; then \
        userdel -r "$(getent passwd "${USER_UID}" | cut -d: -f1)" 2>/dev/null || true; \
    fi; \
    if ! getent group "${USER_GID}" >/dev/null; then \
        groupadd -g "${USER_GID}" "${USERNAME}"; \
    fi; \
    useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash "${USERNAME}"; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

# ---------------------------------------------------------------------------
# Rust
#
# Installed system-wide so the toolchain lives in the image while only the
# registry cache is a volume. Mirrors the layout of the official rust image.
# ---------------------------------------------------------------------------
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

RUN set -eux; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path \
          --default-toolchain "${RUST_TOOLCHAIN}" \
          -c rust-analyzer -c clippy -c rustfmt -c rust-src; \
    chmod -R a+w "${RUSTUP_HOME}" "${CARGO_HOME}"; \
    rustc --version; \
    rust-analyzer --version

# ---------------------------------------------------------------------------
# Python via uv
# ---------------------------------------------------------------------------
ENV UV_TOOL_DIR=/opt/uv-tools \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_PYTHON_INSTALL_DIR=/opt/python

RUN curl -LsSf https://astral.sh/uv/install.sh \
      | env UV_INSTALL_DIR=/usr/local/bin sh

RUN set -eux; \
    uv python install "${PYTHON_VERSION}"; \
    uv tool install basedpyright; \
    uv tool install ruff; \
    # Dedicated env for the debug adapter so it is always available regardless
    # of which project venv is active.
    uv venv /opt/debugpy --python "${PYTHON_VERSION}"; \
    uv pip install --python /opt/debugpy/bin/python debugpy; \
    chmod -R a+rX /opt/python /opt/uv-tools /opt/debugpy

# ---------------------------------------------------------------------------
# Helix and evil-helix
#
# Two builds of the same editor live side by side, both shipping a binary named
# hx and both honouring HELIX_RUNTIME. So HELIX_RUNTIME is deliberately NOT set
# as an image-wide ENV: whichever value won would silently hand one editor the
# other's grammars. config/bin/hx and config/bin/ehx set it per process, which
# is also what keeps the two off each other's config.
# ---------------------------------------------------------------------------
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) hxarch=x86_64 ;; \
        arm64) hxarch=aarch64 ;; \
        *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/helix.tar.xz \
        "https://github.com/helix-editor/helix/releases/download/${HELIX_VERSION}/helix-${HELIX_VERSION}-${hxarch}-linux.tar.xz"; \
    mkdir -p /opt/helix; \
    tar -xJf /tmp/helix.tar.xz -C /opt/helix --strip-components=1; \
    rm /tmp/helix.tar.xz

# evil-helix is a soft fork of Helix with Vim keybindings compiled into the
# editor rather than bolted on as config, kept here as a third option for
# muscle memory that predates Helix's selection-first model. Its own binary is
# also called hx, so it gets a separate prefix and is invoked as `ehx`.
#
# Note the different arch spelling: this project publishes amd64/aarch64, not
# helix's x86_64/aarch64.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) eharch=amd64 ;; \
        arm64) eharch=aarch64 ;; \
        *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/evil-helix.tar.gz \
        "https://github.com/usagi-flow/evil-helix/releases/download/${EVIL_HELIX_VERSION}/evil-helix-${eharch}-linux.tar.gz"; \
    mkdir -p /opt/evil-helix; \
    tar -xzf /tmp/evil-helix.tar.gz -C /opt/evil-helix --strip-components=1; \
    rm /tmp/evil-helix.tar.gz

COPY --chmod=0755 config/bin/hx config/bin/ehx /usr/local/bin/

RUN set -eux; \
    hx --version; \
    ehx --version

# ---------------------------------------------------------------------------
# Neovim
#
# Still the upstream tarball on 26.04, though for a different reason than on
# 24.04 (which packaged 0.9.5 and was simply too old). Resolute ships 0.11.6,
# which does run this config, but 0.12.0 landed just after the LTS freeze and
# an LTS will not rebase, so apt would leave us a minor version behind for five
# years while the plugin stack keeps moving. The tarball is pinned and cheap.
# ---------------------------------------------------------------------------
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) nvarch=x86_64 ;; \
        arm64) nvarch=arm64 ;; \
        *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/nvim.tar.gz \
        "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-${nvarch}.tar.gz"; \
    mkdir -p /opt/nvim; \
    tar -xzf /tmp/nvim.tar.gz -C /opt/nvim --strip-components=1; \
    ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim; \
    rm /tmp/nvim.tar.gz; \
    nvim --version | head -n1

# ---------------------------------------------------------------------------
# User-level configuration
# ---------------------------------------------------------------------------
USER ${USERNAME}
ENV PATH=/home/${USERNAME}/.local/bin:$PATH
WORKDIR /home/${USERNAME}

COPY --chown=${USER_UID}:${USER_GID} config/helix/ .config/helix/
# Only config.toml. languages.toml is shared from .config/helix above, so the
# LSP and DAP setup has one home rather than two that drift apart.
COPY --chown=${USER_UID}:${USER_GID} config/evil-helix/ .config/evil-helix/
COPY --chown=${USER_UID}:${USER_GID} config/nvim/  .config/nvim/
COPY --chown=${USER_UID}:${USER_GID} config/tmux.conf .tmux.conf
COPY --chown=${USER_UID}:${USER_GID} config/bashrc.extra /tmp/bashrc.extra

RUN cat /tmp/bashrc.extra >> "/home/${USERNAME}/.bashrc" \
    && rm /tmp/bashrc.extra \
    && git lfs install --skip-repo \
    && mkdir -p "/home/${USERNAME}/src" \
                "/home/${USERNAME}/.config/git" \
                "/home/${USERNAME}/.claude"

# Bake plugins and treesitter parsers into the image so first launch is instant
# and works with no network.
RUN nvim --headless "+Lazy! sync" +qa 2>&1 | tail -n 30 \
    && nvim --headless "+TSUpdateSync" +qa 2>&1 | tail -n 30 \
    || echo "NOTE: some parsers failed to build; run :TSUpdate in the container"

# Claude Code. The native installer needs no Node.js and drops a self-contained
# binary in ~/.local/bin. Credentials land in ~/.claude, which is a volume.
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && "/home/${USERNAME}/.local/bin/claude" --version

WORKDIR /home/${USERNAME}/src

# Keep the container alive independently of any client. This is the whole point:
# nothing here depends on a connection surviving your laptop suspending.
CMD ["sleep", "infinity"]
