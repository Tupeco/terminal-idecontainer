-- Quick reference, rendered from TIPS.md.
--
-- TIPS.md is bind-mounted read-only at ~/.config/nvim/TIPS.md by
-- docker-compose, so there is exactly one source of truth: edit the file in the
-- repo and both `:Tips` and the startup greeting follow immediately, with no
-- rebuild. Nothing here needs a plugin.

local M = {}

local function tips_path()
  for _, p in ipairs({
    vim.fn.stdpath("config") .. "/TIPS.md",
    vim.env.DEVCONTAINER_TIPS or "",
  }) do
    if p ~= "" and vim.fn.filereadable(p) == 1 then return p end
  end
end

-- Markdown leftovers that mean nothing in a plain-text buffer. The `\|` case
-- matters: a literal pipe inside a table cell has to be escaped in the source.
local function clean(s)
  return (s:gsub("\\|", "|"):gsub("`", ""):gsub("%*%*", ""):gsub("%*", ""))
end

--- The "## Quick reference" section, with its tables flattened into aligned
--- columns. Prose inside the section is skipped so the result stays scannable.
function M.quick_reference()
  local path = tips_path()
  if not path then
    return {
      "  TIPS.md was not found.",
      "",
      "  It is bind-mounted from the repo root; check the volumes list in",
      "  docker-compose.yml, then `./dev up`.",
    }
  end

  local out, rows, inside = {}, {}, false

  -- Emit the pending table with column one padded to its widest entry.
  local function flush()
    local w = 0
    for _, r in ipairs(rows) do w = math.max(w, #r[1]) end
    for _, r in ipairs(rows) do
      table.insert(out, string.format("   %-" .. w .. "s   %s", r[1], r[2]))
    end
    rows = {}
  end

  for line in io.lines(path) do
    if line:match("^## Quick reference") then
      inside = true
    elseif inside and line:match("^## ") then
      break
    elseif inside then
      local group = line:match("^%*%*(.+)%*%*%s*$")
      local a, b = line:match("^|%s*(.-)%s*|%s*(.-)%s*|%s*$")
      if group then
        flush()
        if #out > 0 then table.insert(out, "") end
        table.insert(out, " " .. group)
      elseif a and not a:match("^%-%-") and not (a == "" and b == "") then
        table.insert(rows, { clean(a), clean(b) })
      end
    end
  end
  flush()
  return out
end

function M.greeting()
  local head = {
    "",
    "  Quick reference        :Tips for the full notes  ·  <leader>fk searches every key",
    "",
  }
  local tail = { "", "  q or i dismisses this", "" }
  return vim.list_extend(vim.list_extend(head, M.quick_reference()), tail)
end

--- Open the whole of TIPS.md in a float: searchable, with markdown highlighting.
function M.open()
  local path = tips_path()
  if not path then
    vim.notify("TIPS.md not found — see the volumes list in docker-compose.yml", vim.log.levels.WARN)
    return
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local w = math.min(110, math.floor(vim.o.columns * 0.9))
  local h = math.floor(vim.o.lines * 0.9)
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = w,
    height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
    border = "rounded",
    title = " TIPS.md ",
    title_pos = "center",
  })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, desc = "Close tips" })
end

-- Greet on a startup that has nothing else to show: no arguments, or a single
-- directory (the `nvim .` case, where neo-tree takes the sidebar and leaves an
-- empty editor window). A named file argument means you came here to work.
local function should_greet()
  if vim.fn.argc() > 1 then return false end
  if vim.fn.argc() == 1 and vim.fn.isdirectory(vim.fn.argv(0)) == 0 then return false end
  return true
end

local function empty_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_get_name(buf) == ""
        and vim.bo[buf].buftype == ""
        and not vim.bo[buf].modified
        and vim.api.nvim_buf_line_count(buf) <= 1
        and (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") == ""
      then
        return win, buf
      end
    end
  end
end

function M.setup()
  vim.api.nvim_create_user_command("Tips", M.open, { desc = "Open TIPS.md in a float" })

  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    group = vim.api.nvim_create_augroup("devtips_greeting", { clear = true }),
    callback = function()
      if not should_greet() then return end
      -- Scheduled so neo-tree has finished claiming its sidebar first;
      -- otherwise the window we want to fill may not exist yet.
      vim.schedule(function()
        local win, buf = empty_window()
        if not win then return end
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "wipe"
        vim.bo[buf].swapfile = false
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.greeting())
        vim.bo[buf].modifiable = false
        vim.bo[buf].modified = false
        vim.wo[win].number = false
        vim.wo[win].relativenumber = false
        vim.wo[win].cursorline = false
        vim.wo[win].signcolumn = "no"
        vim.wo[win].winbar = ""
        for _, key in ipairs({ "q", "i" }) do
          vim.keymap.set("n", key, "<cmd>enew<cr>", { buffer = buf, nowait = true, desc = "Dismiss greeting" })
        end
      end)
    end,
  })
end

return M
