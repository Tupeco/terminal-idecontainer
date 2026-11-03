-- Auto-imports from installed packages that no open file imports yet.
--
-- basedpyright offers an auto-import (`DataFr` → `DataFrame`, adding
-- `from pandas import DataFrame`) only from modules already in its program,
-- which in practice means packages some open buffer imports. Measured with
-- basedpyright 1.40.2 and a package in the project's .venv:
--
--   an open buffer imports the package             offered
--   that buffer closed                             not offered
--   a saved, closed project file imports it        not offered
--   the same with diagnosticMode = "workspace"     not offered
--
-- Pylance indexes installed packages for this; basedpyright still reads
-- Pylance's `indexing` setting but nothing in 1.40.2 uses the value.
--
-- Feeding basedpyright an index of its own works, but costs too much: a
-- document importing all 39 top-level packages of a numpy/pandas/scipy/
-- django/boto3 venv took the server from 488 to 651 MB at once and to
-- 1002 MB after a session, slowed bare-name completion from 30-180 ms to
-- 150-850 ms, and filled the list with re-exports from untyped libraries
-- (`defaultdict` from `pandas.core.apply`).
--
-- So the index lives here instead. pyexports.py, run with the project's
-- interpreter, reads each top-level package's `__init__` without importing it
-- and lists what it exports; the result is cached per environment. This
-- module offers those names as an nvim-cmp source, and on confirm adds
-- `from pkg import Name` to the buffer. From then on the package is imported,
-- basedpyright binds it, and its own completion takes over. The server never
-- sees the index, so it costs basedpyright nothing.
--
-- To avoid offering a name twice, a package that any loaded Python buffer
-- already imports is left out: basedpyright already offers its exports, with
-- better information than a read of the source can give.
local M = {}

-- pyexports.py sits beside this file.
local SCRIPT = debug.getinfo(1, "S").source:sub(2):gsub("%.lua$", ".py")
local CACHE_DIR = vim.fn.stdpath("cache") .. "/pyexports"

-- LSP CompletionItemKind numbers, so the menu shows the usual kind labels.
local KIND = { class = 7, ["function"] = 3, variable = 6, constant = 21, module = 9 }

-- One index per interpreter:
--   { items = { [initial] = { item, ... } }, fingerprint, loaded_at, loading }
local indexes = {}

--- The interpreter basedpyright resolves this buffer's imports in. init.lua's
--- before_init puts a found venv into the client's settings; without one
--- basedpyright uses python3 on PATH, and so does this.
local function python_for(bufnr)
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "basedpyright" })[1]
  if not client then return nil end
  return vim.tbl_get(client.settings or {}, "python", "pythonPath") or "python3"
end

--- (Re)load the index for `python` in the background, unless it was loaded
--- less than `min_age` ms ago. The script answers from its cache unless the
--- installed distributions changed, so a run is cheap: ~40 ms for a 400 MB
--- venv, 0.35 s uncached. It runs when basedpyright attaches to a buffer (at
--- most every 5 s, as opening a dozen files attaches a dozen times) and from
--- completion at most every 30 s, which is what picks up a `uv add` without
--- a restart.
local function refresh(python, min_age)
  local idx = indexes[python] or {}
  indexes[python] = idx
  if idx.loading or (idx.loaded_at and vim.uv.now() - idx.loaded_at < min_age) then return end
  idx.loading = true
  vim.system({ python, "-I", SCRIPT, CACHE_DIR }, { text = true }, function(res)
    vim.schedule(function()
      idx.loading = false
      idx.loaded_at = vim.uv.now()
      local ok, data = pcall(vim.json.decode, res.stdout or "")
      if res.code ~= 0 or not ok or type(data) ~= "table" then
        idx.error = vim.trim(res.stderr or "") ~= "" and vim.trim(res.stderr) or "no output"
        return
      end
      idx.error = nil
      if data.fingerprint == idx.fingerprint then return end
      idx.fingerprint = data.fingerprint
      -- Grouped by lower-cased first letter: nvim-cmp's matcher requires the
      -- first character to match, so a request only ever needs one group,
      -- and the item tables are built once here rather than per keystroke.
      local items, count = {}, 0
      for pkg, names in pairs(data.packages or {}) do
        for _, nk in ipairs(names) do
          local name, kind = nk[1], nk[2]
          local key = name:sub(1, 1):lower()
          items[key] = items[key] or {}
          table.insert(items[key], {
            label = name,
            kind = KIND[kind] or KIND.variable,
            labelDetails = { description = pkg },
            detail = ("from %s import %s"):format(pkg, name),
            data = { pkg = pkg },
          })
          count = count + 1
        end
      end
      idx.items = items
      idx.count = count
      idx.packages = vim.tbl_count(data.packages or {})
    end)
  end)
end

-- Top-level packages each buffer imports, recomputed only when it changes.
local imports_cache = {}

local function buffer_imports(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = imports_cache[bufnr]
  if cached and cached.tick == tick then return cached.pkgs end
  local pkgs = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local list = line:match("^%s*import%s+(.+)")
    if list then
      for part in list:gmatch("[^,]+") do
        local pkg = part:match("^%s*([%a_][%w_]*)")
        if pkg then pkgs[pkg] = true end
      end
    else
      local pkg = line:match("^%s*from%s+([%a_][%w_]*)")
      if pkg then pkgs[pkg] = true end
    end
  end
  imports_cache[bufnr] = { tick = tick, pkgs = pkgs }
  return pkgs
end

--- Packages basedpyright already offers auto-imports from: those any loaded
--- Python buffer imports.
local function covered_packages()
  local covered = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "python" then
      for pkg in pairs(buffer_imports(b)) do covered[pkg] = true end
    end
  end
  return covered
end

--- True inside a string or comment, where a bare-name completion that adds an
--- import would be wrong.
local function in_string_or_comment(bufnr, row, col)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, math.max(col - 1, 0) } })
  while ok and node do
    local t = node:type()
    if t == "string" or t == "comment" or t == "string_content" then return true end
    node = node:parent()
  end
  return false
end

local IMPORT_NODES = { import_statement = true, import_from_statement = true, future_import_statement = true }

--- Add `from pkg import name` to `bufnr`: after the module's leading
--- imports, or after its docstring, or at the top below a shebang or coding
--- line. Never merged into an existing `from pkg import ...`, because there is
--- none: a buffer importing `pkg` takes `pkg` out of this source's offers.
--- Ordering is left to ruff (`<leader>ca`, "Organize imports"), as it is for
--- basedpyright's own auto-imports.
local function add_import(bufnr, pkg, name)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local row = 0
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "python")
  if ok and parser then
    local root = parser:parse()[1]:root()
    local seen_statement = false
    for child in root:iter_children() do
      local t = child:type()
      if IMPORT_NODES[t] then
        row = child:end_() + 1
      elseif t == "comment" then
        -- comments between imports do not end the block
      elseif not seen_statement and t == "expression_statement"
        and child:named_child(0) and child:named_child(0):type() == "string" then
        row = child:end_() + 1 -- docstring
      else
        break
      end
      if t ~= "comment" then seen_statement = true end
    end
  end
  if row == 0 then
    while lines[row + 1] and (lines[row + 1]:match("^#!") or lines[row + 1]:match("^#.*coding[:=]")) do
      row = row + 1
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, { ("from %s import %s"):format(pkg, name) })
end

local source = {}

function source:get_debug_name() return "pyexports" end

function source:is_available()
  return vim.bo.filetype == "python"
end

function source:get_keyword_pattern() return [[\h\w*]] end

function source:complete(params, callback)
  local bufnr = params.context.bufnr
  local python = python_for(bufnr)
  if not python then return callback() end
  refresh(python, 30000)
  local idx = indexes[python]
  if not idx or not idx.items then return callback() end

  local before = params.context.cursor_before_line
  local word = before:match("[%a_][%w_]*$")
  if not word then return callback() end
  local lead = before:sub(1, #before - #word)
  -- Member access (`np.lin`) and import statements are basedpyright's.
  if lead:match("%.%s*$") or before:match("^%s*import%s") or before:match("^%s*from%s") then
    return callback()
  end
  local cursor = params.context.cursor
  if in_string_or_comment(bufnr, cursor.row - 1, cursor.col - 1) then return callback() end

  local covered = covered_packages()
  local out = {}
  for _, item in ipairs(idx.items[word:sub(1, 1):lower()] or {}) do
    if not covered[item.data.pkg] then out[#out + 1] = item end
  end
  callback({ items = out, isIncomplete = false })
end

-- After the name is inserted. Done here rather than as additionalTextEdits:
-- nvim-cmp drops an additional edit whose range touches the cursor line, and
-- in a file with no imports yet the new line goes exactly there.
function source:execute(item, callback)
  local bufnr = vim.api.nvim_get_current_buf()
  vim.cmd("silent! undojoin")
  add_import(bufnr, item.data.pkg, item.label)
  callback(item)
end

--- Register the nvim-cmp source and load an index whenever basedpyright
--- attaches. Called from nvim-cmp's config in init.lua.
function M.setup()
  require("cmp").register_source("pyexports", source)
  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("pyexports", { clear = true }),
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and client.name == "basedpyright" then
        local python = python_for(args.buf)
        if python then refresh(python, 5000) end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = "pyexports",
    callback = function(args) imports_cache[args.buf] = nil end,
  })
end

--- For :checkhealth-style inspection: `:lua =require("pyexports").status()`.
function M.status()
  local out = {}
  for python, idx in pairs(indexes) do
    out[python] = { packages = idx.packages, names = idx.count, loading = idx.loading, error = idx.error }
  end
  return out
end

return M
