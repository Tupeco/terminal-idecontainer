-- Auto-import completions for installed packages that no open file imports.
--
-- basedpyright offers an auto-import (`frob` → `frobnicate`, adding
-- `from fancylib import frobnicate`) only for modules already in its program:
-- the open buffers and what they import. A package that no open buffer
-- imports is never offered, however long the server has been running.
-- Measured with basedpyright 1.40.2 and a package in the project's .venv:
--
--   an open buffer imports the package             offered
--   that buffer closed                             not offered
--   a saved, closed project file imports it        not offered
--   the same with diagnosticMode = "workspace"     not offered
--
-- The candidates come from `buildModuleSymbolsMap` over
-- `program.getSourceFileInfoList()`. Pylance fills the gap with an index of
-- installed packages, and basedpyright still reads Pylance's `indexing`
-- setting, but nothing in 1.40.2 uses the value.
--
-- So build the index here. When a basedpyright client starts, list the
-- top-level packages in the environment it resolves imports in, and open a
-- document that imports each of them. It is never a Neovim buffer, only a
-- `textDocument/didOpen` sent to the server, so it has no window, no swap
-- file, and no pull-diagnostics request (Nvim asks only for its buffers).
-- The server parses and binds every package's `__init__` and what that
-- imports, and from then on offers their names. Like Pylance's default, this
-- covers what the top-level package exports, not its submodules.
--
-- Each import is written `import pkg as _pkg_`. A private name is not an
-- auto-import candidate itself, so the index never offers
-- `from <index> import numpy`.
--
-- What it costs, measured on a venv of 39 top-level packages (numpy, pandas,
-- scipy, matplotlib, django, boto3, pydantic, fastapi, sqlalchemy, requests,
-- httpx and their dependencies):
--
--                                        index off     index on
--   index bound after on_init            -             1.6 s
--   basedpyright RSS, settled            488 MB        651 MB
--   RSS after ~25 completions            605 MB        1002 MB
--   completing a bare name (DataFr)      30-180 ms     150-850 ms, 1.8 s worst
--   member completion (os.pa)            15-90 ms      unchanged
--
-- The list is also noisier. Libraries without type information count every
-- name they import as public, so `defaultd` offers `defaultdict` from
-- `pandas.core.apply` and `sqlalchemy.util` beside `collections`, and the
-- noise grows as completions bind more of each library. Standard-library
-- names need none of this: basedpyright offers those (`defaultdict
-- [collections]`) with or without the index.
local M = {}

-- The document's path. Inside the root, so basedpyright files it under the
-- client's own workspace and resolves its imports with that workspace's
-- python.pythonPath; a path elsewhere lands in the server's default workspace,
-- which has none. Nothing is written there.
local INDEX_NAME = "__nvim_library_index__.py"

-- Installed but not worth offering: packaging tools that sit in every venv,
-- whose names would only crowd the list.
local SKIP = {
  pip = true, setuptools = true, pkg_resources = true, wheel = true,
  test = true, tests = true,
}

--- Top-level importable names in one site-packages directory. A package is a
--- directory with `__init__.py(i)` or a stub-only `<name>-stubs`; a module is a
--- `.py`, `.pyi` or compiled extension. Namespace packages (no `__init__`,
--- such as `google`) are left out: importing one binds nothing to offer.
local function scan(dir, into)
  for name, kind in vim.fs.dir(dir) do
    local mod
    if kind == "directory" or kind == "link" then
      local stub = name:match("^(.+)%-stubs$")
      if stub then
        mod = stub
      elseif vim.uv.fs_stat(dir .. "/" .. name .. "/__init__.py")
        or vim.uv.fs_stat(dir .. "/" .. name .. "/__init__.pyi") then
        mod = name
      end
    else
      mod = name:match("^([%w_]+)%.pyi?$") or name:match("^([%w_]+)%..*%.so$")
        or name:match("^([%w_]+)%.so$") or name:match("^([%w_]+)%..*%.pyd$")
    end
    if mod and mod:match("^[%a][%w_]*$") and not SKIP[mod] then
      into[mod] = true
    end
  end
end

--- The site-packages directories of `python`, from the interpreter itself:
--- a venv has one, while Debian's system Python has three
--- (/usr/local/lib/python3.X/dist-packages, /usr/lib/python3/dist-packages,
--- /usr/lib/python3.X/dist-packages) and no fixed layout to guess.
local function site_dirs(python, cb)
  vim.system(
    { python, "-I", "-c", "import site; print('\\n'.join(site.getsitepackages()))" },
    { text = true },
    function(res)
      cb(res.code == 0 and vim.split(vim.trim(res.stdout or ""), "\n", { trimempty = true }) or {})
    end
  )
end

--- Open the index document in `client`. Called from basedpyright's on_init,
--- so once per client: `:lsp restart` builds a fresh index, which is how
--- packages installed since the server started get picked up.
function M.attach(client)
  if vim.g.pylibindex == false then return end
  local root = client.root_dir
  if not root then return end
  local python = vim.tbl_get(client.settings or {}, "python", "pythonPath") or "python3"
  local t0 = vim.uv.hrtime()
  site_dirs(python, function(dirs)
    vim.schedule(function()
      if client:is_stopped() then return end
      local mods = {}
      for _, dir in ipairs(dirs) do scan(dir, mods) end
      local names = vim.tbl_keys(mods)
      table.sort(names)
      local lines = {
        "# Library index for auto-import completions, opened by pylibindex.lua.",
        "# Not a file on disk; see that module for why it exists.",
      }
      for _, n in ipairs(names) do
        lines[#lines + 1] = ("import %s as _%s_"):format(n, n)
      end
      local uri = vim.uri_from_fname(root .. "/" .. INDEX_NAME)
      client:notify("textDocument/didOpen", {
        textDocument = {
          uri = uri,
          languageId = "python",
          version = 1,
          text = table.concat(lines, "\n") .. "\n",
        },
      })
      -- Opening the document is not enough. A library file is a candidate
      -- only once it is bound (`getModuleSymbolTable` returns its symbols),
      -- and an `import` line resolves the module without binding it. Something
      -- has to evaluate each imported name. A diagnostics pull does not: the
      -- checker leaves an unused import alone, and with only didOpen plus
      -- `textDocument/diagnostic` nothing was offered. Semantic tokens do,
      -- because classifying `_pkg_` as a namespace evaluates the module. (A
      -- real buffer gets semantic tokens from Nvim, which is why an import in
      -- an open buffer was enough in the measurements above.) The tokens
      -- themselves are thrown away.
      client:request("textDocument/semanticTokens/full", { textDocument = { uri = uri } },
        function(err)
          M.last = { root = root, python = python, count = #names, err = err,
            ms = (vim.uv.hrtime() - t0) / 1e6 }
        end)
    end)
  end)
end

return M
