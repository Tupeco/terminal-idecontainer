# syntax=docker/dockerfile:1
#
# Polyglot terminal dev container: Helix + Neovim, Python + Rust, Claude Code.
# Designed to be lived in via tmux, so a host suspend never breaks your session.

FROM ubuntu:24.04

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

# Pinned so rebuilds are reproducible. Bump deliberately.
ARG HELIX_VERSION=25.07.1
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

# The DAP binary moved from lldb-vscode to lldb-dap in LLVM 18 and is versioned
# on Ubuntu. Find whatever is actually there and give it a stable name.
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
# Ubuntu 24.04 ships a stock 'ubuntu' account already occupying UID 1000, which
# collides with the typical host UID. Remove it before creating ours.
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
# Helix
# ---------------------------------------------------------------------------
ENV HELIX_RUNTIME=/opt/helix/runtime

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
    ln -sf /opt/helix/hx /usr/local/bin/hx; \
    rm /tmp/helix.tar.xz; \
    hx --version

# ---------------------------------------------------------------------------
# Neovim
#
# Ubuntu 24.04 only packages 0.9.5, which is too old for current plugin stacks,
# so take the upstream tarball.
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
