-- Jump from a file path printed in a terminal buffer to the file itself.
--
-- Built for ripgrep's default terminal output, which is *heading* mode: the
-- path sits on its own line and the matches follow it, numbered.
--
--     src/bar.py
--     1:x = TARGET
--     3:TARGET
--
-- so the line number and the path are never on the same line. Piped output
-- (`path:42:13:text`, `rg --vimgrep`) is handled too, since that is what you
-- get the moment the command has a `| less` on the end.

local M = {}

--- The cwd of the shell running in this terminal buffer, if we can see it.
--- More reliable than Nvim's cwd: you may well have cd'd since opening it.
local function terminal_cwd(bufnr)
  local chan = vim.b[bufnr].terminal_job_id
  if not chan then return nil end
  local ok, pid = pcall(vim.fn.jobpid, chan)
  if not ok or type(pid) ~= "number" then return nil end
  return (vim.uv.fs_readlink("/proc/" .. pid .. "/cwd"))
end

--- Directories a relative path might be relative to, best guess first.
local function roots(bufnr)
  local list, seen = {}, {}
  local function add(d)
    if d and d ~= "" and not seen[d] then
      seen[d] = true
      list[#list + 1] = d
    end
  end
  add(terminal_cwd(bufnr))
  add(vim.fn.getcwd())
  add(vim.fs.root(vim.fn.getcwd(), ".git"))
  return list
end

local function resolve(path, bufnr)
  if not path or path == "" then return nil end
  path = vim.fn.expand(path)
  local function isfile(p)
    local st = vim.uv.fs_stat(p)
    return st and st.type == "file" and p or nil
  end
  if vim.startswith(path, "/") then return isfile(path) end
  for _, root in ipairs(roots(bufnr)) do
    local hit = isfile(root .. "/" .. path)
    if hit then return hit end
  end
  return nil
end

-- A numbered line in rg's output: "42:match" or, with context, "42-context".
local function match_line_number(s)
  return s:match("^%s*(%d+)[:%-]")
end

--- Returns resolved path, line number, and the token we tried (for the
--- fallback query).
function M.locate()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local cfile = vim.fn.expand("<cfile>")

  -- 1. A path directly under the cursor. `:` is not in 'isfname', so <cfile>
  --    already stops at the colon in "src/foo.py:42:13:text".
  local target = resolve(cfile, bufnr)
  if target then
    local lnum = line:match(vim.pesc(cfile) .. ":(%d+)")
    return target, tonumber(lnum) or 1, cfile
  end

  -- 2. A numbered match line: walk up to the heading that owns it.
  local lnum = match_line_number(line)
  if lnum then
    for r = row - 1, math.max(1, row - 500), -1 do
      local prev = vim.api.nvim_buf_get_lines(bufnr, r - 1, r, false)[1] or ""
      if not match_line_number(prev) then
        -- A blank line separates blocks, so the heading is never above one.
        if prev:match("^%s*$") then break end
        local hit = resolve(vim.trim(prev), bufnr)
        if hit then return hit, tonumber(lnum), vim.trim(prev) end
        break
      end
    end
  end

  return nil, nil, (cfile ~= "" and cfile or vim.fn.expand("<cWORD>"))
end

--- The window to open the file in: the one you were last editing in, never
--- the terminal you are standing in and never the file tree.
local function editor_win()
  local function usable(win)
    if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then return false end
    if vim.api.nvim_win_get_config(win).relative ~= "" then return false end
    local b = vim.api.nvim_win_get_buf(win)
    return vim.bo[b].buftype == "" and vim.bo[b].filetype ~= "neo-tree"
  end
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if usable(prev) then return prev end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) then return win end
  end
  return nil
end

local function goto_editor_win()
  local win = editor_win()
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd("topleft split")
  end
end

function M.jump()
  local path, lnum, token = M.locate()
  if path then
    goto_editor_win()
    vim.cmd.edit(vim.fn.fnameescape(path))
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum or 1, 0 })
    vim.cmd("normal! zvzz")
    return
  end

  -- Fall back to the picker, seeded with just the file name: a fuzzy query
  -- full of slashes matches badly, and the directory part is the part most
  -- likely to be wrong when we got here.
  local name = vim.fs.basename(token or "")
  if name == "" then
    vim.notify("No file path under the cursor", vim.log.levels.WARN)
    return
  end
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("No such file: " .. tostring(token), vim.log.levels.WARN)
    return
  end
  vim.notify("No such file: " .. tostring(token) .. " — searching for " .. name,
    vim.log.levels.WARN)
  goto_editor_win()
  fzf.files({ query = name })
end

return M
