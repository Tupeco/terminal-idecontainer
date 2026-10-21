-- Narrated code walkthroughs: the Neovim half.
--
-- Claude Code drives this through nvim-mcp's `exec_lua` tool, one stop at a
-- time:
--
--   return require('walkthrough').show('dev', 120, 148, 'Choosing a port')
--   -- ...then the narrator's `speak` about those lines, which blocks until heard
--   return require('walkthrough').clear()
--
-- and `:Walkthrough` starts such a session: a Claude Code terminal in a split,
-- given a prompt that spells out that protocol. The narrator (the MCP server
-- that speaks, and its browser player) is described in README.md under
-- "Narrated walkthroughs"; without it the same walkthrough works with the
-- narration written in Claude's chat instead.
--
-- Helpers rather than leaving Claude to compose raw API calls: a highlight that
-- lands in the terminal window Claude itself is running in, or a range that
-- scrolls half off screen, is the kind of mistake that is easy to make over
-- RPC and tedious to explain back. Here the choice of window and the scrolling
-- are made once.

local M = {}

local ns = vim.api.nvim_create_namespace("walkthrough")

-- Linked rather than coloured, so they follow the colorscheme. `default`
-- leaves a colorscheme free to style them properly.
vim.api.nvim_set_hl(0, "WalkthroughRange", { link = "Visual", default = true })
vim.api.nvim_set_hl(0, "WalkthroughLabel", { link = "Title", default = true })

-- The window the last stop was shown in, reused while it stays suitable so the
-- code does not hop between splits from one stop to the next.
local last_win = nil

local function is_code_window(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  if vim.api.nvim_win_get_config(win).relative ~= "" then return false end
  -- buftype "" is an ordinary file buffer: not a terminal (possibly the one
  -- Claude is running in), not neo-tree, not help, not a quickfix list.
  return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

-- The previous stop's window, else the largest code window in this tab, else a
-- new split. The split is made without moving focus, so typing into Claude's
-- terminal is never interrupted.
local function code_window()
  if last_win and is_code_window(last_win)
      and vim.api.nvim_win_get_tabpage(last_win) == vim.api.nvim_get_current_tabpage() then
    return last_win
  end
  local best, area = nil, -1
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_code_window(win) then
      local a = vim.api.nvim_win_get_width(win) * vim.api.nvim_win_get_height(win)
      if a > area then best, area = win, a end
    end
  end
  if best then return best end
  -- A scratch buffer that vanishes once show() edits the file into the window.
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].bufhidden = "wipe"
  return vim.api.nvim_open_win(scratch, false, { split = "left", win = 0 })
end

--- Show lines `first`..`last` (1-based, inclusive) of `path`, highlighted, with
--- an optional `label` above them. Clears the previous stop's highlight.
--- `path` is relative to Neovim's working directory, or absolute.
function M.show(path, first, last, label)
  M.clear()
  local win = code_window()
  last_win = win
  local abs = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(abs) == 0 then
    error("walkthrough: no such file: " .. path)
  end
  local buf
  vim.api.nvim_win_call(win, function()
    if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p") ~= abs then
      vim.cmd.edit(vim.fn.fnameescape(abs))
    end
    buf = vim.api.nvim_get_current_buf()
  end)

  local count = vim.api.nvim_buf_line_count(buf)
  first = math.max(1, math.min(first, count))
  last = math.max(first, math.min(last or first, count))

  vim.api.nvim_buf_set_extmark(buf, ns, first - 1, 0, {
    end_row = last - 1,
    line_hl_group = "WalkthroughRange",
    virt_lines = label and { { { "▶ " .. label, "WalkthroughLabel" } } } or nil,
    virt_lines_above = true,
  })

  -- Centre the range if it fits, else start at its top. Measured in buffer
  -- lines, which is close enough with 'wrap' off, the default in this config.
  local height = vim.api.nvim_win_get_height(win) - (label and 1 or 0)
  local span = last - first + 1
  local top = span < height and math.max(1, first - math.floor((height - span) / 2)) or first
  vim.api.nvim_win_call(win, function()
    -- topfill = 1 keeps the label's virtual line visible when the range starts
    -- at the very top of the window.
    vim.fn.winrestview({ topline = top, topfill = label and 1 or 0, lnum = first, col = 0 })
  end)
  return string.format("showing %s:%d-%d", vim.fn.fnamemodify(abs, ":~:."), first, last)
end

--- Remove the walkthrough highlight from every buffer.
function M.clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  return "cleared"
end

-- What `:Walkthrough` asks of Claude. The steps are explicit because the
-- timing depends on them: highlight first, then a `speak` that blocks, so the
-- right lines are on screen for exactly as long as they are being talked about.
local function prompt(topic)
  return table.concat({
    "Give me a narrated walkthrough of " .. topic .. ".",
    "",
    "You control my Neovim through the `nvim` MCP server (nvim-mcp) and speak aloud through the `narrator` MCP server.",
    "",
    "1. Read the code first. Plan 4 to 12 stops in an order that tells the story of how it works, and post the plan as one short list.",
    "2. Call narrator `status`. If no player is connected, ask me to open the address that `./dev narrator-url` prints on the host, and wait until I say it is open.",
    "3. For each stop, first highlight it: nvim `exec_lua` with `return require('walkthrough').show('<path relative to the working directory>', <first line>, <last line>, '<label of a few words>')`. Then call narrator `speak` with one to four sentences about those lines. `speak` returns once I have heard them; only then go to the next stop.",
    "4. Write for the ear: no markdown, no symbols spelt out, say \"the setup function\" rather than reading identifiers character by character. Explain why as well as what.",
    "5. If `speak` says I pressed Stop, stop and ask me how to continue. At the end, run `return require('walkthrough').clear()` and offer to go deeper on any stop.",
    "",
    "If nvim-mcp reports no connection, use its `get_targets` and `connect` tools first. If the narrator tools are unavailable, write each stop's narration in chat instead and still move the highlight.",
  }, "\n")
end

-- `:Walkthrough [topic]`, or over a visual range, those lines of this file.
-- With neither, the current file.
function M.command(opts)
  if vim.fn.executable("claude") == 0 then
    vim.notify("Walkthrough: claude is not on PATH", vim.log.levels.ERROR)
    return
  end
  local file = vim.fn.expand("%:.")
  local topic
  if opts.args ~= "" then
    topic = opts.args
  elseif opts.range > 0 and file ~= "" then
    topic = string.format("lines %d to %d of %s", opts.line1, opts.line2, file)
  elseif file ~= "" then
    topic = file
  else
    topic = "this project"
  end
  last_win = vim.api.nvim_get_current_win()
  vim.cmd("botright vnew")
  -- 40% of the screen, but at least 60 columns for Claude's output, as long as
  -- that still leaves the code half the screen.
  local cols = vim.o.columns
  vim.api.nvim_win_set_width(0, math.max(math.floor(cols * 0.4), math.min(60, math.floor(cols / 2))))
  -- An argv list, not a shell string, so the prompt needs no quoting.
  vim.fn.jobstart({ "claude", prompt(topic) }, { term = true })
  vim.cmd.startinsert()
end

function M.setup()
  vim.api.nvim_create_user_command("Walkthrough", M.command, {
    nargs = "*",
    range = true,
    desc = "Narrated walkthrough by Claude Code (of a topic, a range, or this file)",
  })
  vim.api.nvim_create_user_command("WalkthroughClear", function() M.clear() end,
    { desc = "Remove the walkthrough highlight" })
end

return M
