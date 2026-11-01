-- Which language servers are serving the current buffer, and why one that
-- should be is not: two lualine components and `:LspStatus`.
--
-- Written for one specific silence. Nvim 0.12's vim.lsp.enable() checks each
-- server's `cmd` when a buffer gets its filetype, and when the binary is not
-- on $PATH it skips that server without a word on screen: can_start() in
-- runtime/lua/vim/lsp.lua writes
--
--   invalid "basedpyright" config: cmd: expected function or table with
--   executable command, got ... basedpyright-langserver is not executable
--
-- to lsp.log and returns. The file opens normally. nvim-cmp then falls
-- through to its second source group, words from open buffers, so completion
-- looks merely poor rather than absent. `:checkhealth vim.lsp` does print
-- "'basedpyright-langserver' is not executable", but as one line among some
-- 800 of client capabilities (measured with three servers enabled).
--
-- The usual reason the binary is missing is that Neovim was started without
-- the PATH install-scripts/install.sh writes into ~/.profile and ~/.bashrc:
-- from a shell other than bash, from a desktop launcher, or from a terminal
-- opened before the install. `:LspStatus` says when the binary is sitting in
-- one of the directories that script installs to.

local M = {}

--- The configs init.lua enables, in its order. Handed over by setup() rather
--- than read from vim.lsp._enabled_configs, which is private.
local servers = {}

--- Where install-scripts/install.sh puts the servers: uv tools (basedpyright,
--- ruff) in the first, rustup's proxies (rust-analyzer, cargo) in the second.
--- The container has them in /usr/local, which is always on PATH.
local INSTALL_DIRS = { "~/.local/bin", "~/.cargo/bin" }

--- Every enabled server whose filetypes cover buffer `buf`, each with a state:
---   attached  serving this buffer
---   starting  started, has not answered `initialize` yet
---   missing   its binary is not on PATH, so Nvim skipped it
---   off       binary present but no client: still finding its root (rust-
---             analyzer runs `cargo metadata` first), never started, or exited
local function buffer_servers(buf)
  local out = {}
  local ft = vim.bo[buf].filetype
  -- The same test Nvim applies before starting anything: only real files.
  if ft == "" or vim.bo[buf].buftype ~= "" then return out end
  for _, name in ipairs(servers) do
    local cfg = vim.lsp.config[name]
    if cfg and cfg.filetypes and vim.tbl_contains(cfg.filetypes, ft) then
      local e = { name = name, cmd = type(cfg.cmd) == "table" and cfg.cmd[1] or nil }
      -- `_uninitialized` is private. Without it get_clients() hides a client
      -- until the server has answered `initialize`, which for basedpyright is
      -- a second or two, and the status line would call it "not running" in
      -- the meantime. If a later Nvim drops the field, that flash is all that
      -- changes.
      e.client = vim.lsp.get_clients({ bufnr = buf, name = name, _uninitialized = true })[1]
      if e.client then
        e.state = e.client.initialized and "attached" or "starting"
      elseif e.cmd and vim.fn.executable(e.cmd) == 0 then
        e.state = "missing"
      else
        e.state = "off"
      end
      out[#out + 1] = e
    end
  end
  return out
end

--- The installer directory holding `cmd`, as written in INSTALL_DIRS, or nil.
local function install_dir_with(cmd)
  for _, dir in ipairs(INSTALL_DIRS) do
    if vim.fn.executable(vim.fn.expand(dir) .. "/" .. cmd) == 1 then return dir end
  end
end

--- The Python environment basedpyright was given, for display, or nil when it
--- was given none and so uses the python3 on PATH. init.lua's before_init sets
--- it; `:LspPyrightSetPythonPath` changes it.
local function python_path(client)
  return vim.tbl_get(client.settings or {}, "python", "pythonPath")
end

--- ~/code/ws/.venv/bin/python -> "ws/.venv": the venv and the directory it
--- sits in, which tells a workspace's shared .venv from a member's own without
--- spending the status line on a full path.
local function env_label(py)
  local env = py:match("^(.*)/bin/python[%d.]*$") or py
  local parent = vim.fn.fnamemodify(env, ":h:t")
  return (parent ~= "" and parent .. "/" or "") .. vim.fn.fnamemodify(env, ":t")
end

-- ---------------------------------------------------------------------------
-- lualine components
-- ---------------------------------------------------------------------------
-- Next to lualine's own `lsp_status`, which names the servers that are
-- attached and spins while they work (rust-analyzer indexing, say). It never
-- mentions the ones that are not, which is what these are for.

--- Servers that should be serving this buffer and are not, e.g.
--- "⚠ basedpyright not on PATH". Empty, so hidden, when all is well.
function M.unattached()
  local parts, warn = {}, false
  for _, e in ipairs(buffer_servers(vim.api.nvim_get_current_buf())) do
    if e.state == "starting" then
      parts[#parts + 1] = e.name .. " starting"
    elseif e.state == "missing" then
      parts[#parts + 1] = e.name .. " not on PATH"
      warn = true
    elseif e.state == "off" then
      parts[#parts + 1] = e.name .. " not running"
      warn = true
    end
  end
  if #parts == 0 then return "" end
  return (warn and "⚠ " or "") .. table.concat(parts, ", ")
end

--- lualine `color` for the component above: the warning colour while a server
--- is missing or not running, the section's own otherwise. A function, so it
--- follows the colour scheme rather than freezing the colour at startup.
function M.unattached_color()
  for _, e in ipairs(buffer_servers(vim.api.nvim_get_current_buf())) do
    if e.state == "missing" or e.state == "off" then
      local fg = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false }).fg
      return fg and { fg = string.format("#%06x", fg) } or nil
    end
  end
end

--- Which environment basedpyright resolves imports in, for a Python buffer it
--- is serving: "py myproj/.venv", or "py: no venv" when it fell back to the python3
--- on PATH, where only what is installed system-wide will complete.
function M.python_env()
  local buf = vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({ bufnr = buf, name = "basedpyright" })[1]
  if not client then return "" end
  local py = python_path(client)
  return py and ("py " .. env_label(py)) or "py: no venv"
end

-- ---------------------------------------------------------------------------
-- :LspStatus
-- ---------------------------------------------------------------------------

function M.report()
  local buf = vim.api.nvim_get_current_buf()
  local ft = vim.bo[buf].filetype
  local chunks = {}
  local function add(text, hl) chunks[#chunks + 1] = { text, hl } end
  local pad = string.rep(" ", 15)

  local entries = buffer_servers(buf)
  if #entries == 0 then
    add(("No language server is enabled for %s.\n"):format(
      ft == "" and "a buffer without a filetype" or ("filetype '" .. ft .. "'")))
  end

  for _, e in ipairs(entries) do
    add(("%-15s"):format(e.name), "Identifier")
    if e.client then
      if e.state == "attached" then
        add("attached", "DiagnosticOk")
      else
        add("starting: waiting for the server to answer `initialize`", "MoreMsg")
      end
      local root = e.client.root_dir
      add("  root " .. (root and vim.fn.fnamemodify(root, ":~") or "none (single-file mode)"))
      if e.name == "basedpyright" then
        local py = python_path(e.client)
        add("\n" .. pad .. "python ")
        if py then
          add(vim.fn.fnamemodify(py, ":~"))
        else
          add("python3 from PATH: no .venv or venv found from the root upward, none activated",
            "DiagnosticWarn")
        end
      end
    elseif e.state == "missing" then
      add(e.cmd .. " is not on Neovim's PATH, so Nvim skipped this server", "DiagnosticWarn")
      local dir = install_dir_with(e.cmd)
      if dir then
        add(("\n%sIt is in %s, which this Neovim's PATH lacks. Start nvim from a shell that"
          .. "\n%shas it (`. ~/.profile`, or log in again), or add %s to your shell's PATH.")
          :format(pad, dir, pad, dir))
      else
        add(("\n%sNot in %s either. Installed? (install-scripts/install.sh)")
          :format(pad, table.concat(INSTALL_DIRS, " or ")))
      end
    else
      add("not running", "DiagnosticWarn")
      if e.name == "rust_analyzer" and vim.fn.executable("cargo") == 0 then
        -- nvim-lspconfig's root_dir runs `cargo metadata` to find the
        -- workspace, and without cargo it never starts the server.
        add(("\n%scargo is not on Neovim's PATH, and nvim-lspconfig needs it to find the workspace")
          :format(pad))
        local dir = install_dir_with("cargo")
        if dir then add((" (it is in %s)"):format(dir)) end
      else
        add(("\n%sStill starting, or it exited; the log below says which. `:lsp restart` retries.")
          :format(pad))
      end
    end
    add("\n")
  end

  add(("Log: %s    Everything: :checkhealth vim.lsp"):format(
    vim.fn.fnamemodify(vim.lsp.log.get_filename(), ":~")), "Comment")
  vim.api.nvim_echo(chunks, true, {})
end

function M.setup(names)
  servers = names
  vim.api.nvim_create_user_command("LspStatus", M.report,
    { desc = "Which language servers serve this buffer, and why one is missing" })
end

return M
