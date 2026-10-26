-- Narrated code walkthroughs: the Neovim half.
--
-- show(), subtitle() and clear() are called over RPC, one stop at a time:
--
--   require('walkthrough').show('/path/to/dev', 120, 148, 'Choosing a port')
--   require('walkthrough').subtitle('The port is chosen once, at setup...')
--   require('walkthrough').clear()
--
-- by the narrator during a tour (narrator.py, over the socket the nvim-mcp
-- plugin opens), or by Claude Code through nvim-mcp's `exec_lua` when there is
-- no narrator. `:Walkthrough` starts a session in a tab of its own: the tree
-- on the left, the code window the tour drives on the right, and a Claude Code
-- terminal across the bottom, given a prompt that spells out the protocol.
-- `:WalkthroughReplay` does the same for a tour the narrator saved earlier
-- under .tours/, which Claude then only has to hand back to the narrator. The
-- narrator (the MCP server that speaks, and its browser player) is described
-- in README.md under "Narrated walkthroughs"; without it the same walkthrough
-- works with the narration written in Claude's chat instead.
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
vim.api.nvim_set_hl(0, "WalkthroughSubtitle", { link = "NormalFloat", default = true })

-- The window the last stop was shown in, reused while it stays suitable so the
-- code does not hop between splits from one stop to the next. `:Walkthrough`
-- sets it to its tab's code window, and that one is kept even while you are in
-- another tab: the narrator calls show() whenever a stop starts, and taking
-- "this tab" at that moment would drag the tour into whatever you were doing
-- while it played.
local last_win = nil

-- The subtitle float and its buffer, reused from one sentence to the next.
local sub = { win = nil, buf = nil }

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
  if last_win and is_code_window(last_win) then
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

-- Move neo-tree's cursor to the narrated file, without focusing the tree.
-- follow_current_file does not do it: show() edits the file inside
-- nvim_win_call, and by the time neo-tree's scheduled follow handler looks at
-- the current buffer, focus is back in Claude's terminal.
--
-- Only when the code window's tab is the one on screen, because neo-tree keeps
-- one tree per tab and acts on the current one. Only for files under the
-- working directory, too: for anything else neo-tree would ask, in a prompt
-- nobody is looking at, whether to change the tree's root. `dir` is passed so
-- that a tree you navigated elsewhere comes back to the project rather than
-- asking the same question.
local function reveal_in_tree(win, abs)
  if vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then return end
  local cwd = vim.fn.getcwd()
  if abs:sub(1, #cwd + 1) ~= cwd .. "/" then return end
  local has_tree = false
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "neo-tree" then has_tree = true end
  end
  if not has_tree then return end
  pcall(function()
    require("neo-tree.command").execute({
      action = "show", source = "filesystem", dir = cwd, reveal_file = abs,
    })
  end)
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
  reveal_in_tree(win, abs)
  return string.format("showing %s:%d-%d", vim.fn.fnamemodify(abs, ":~:."), first, last)
end

local function close_subtitle()
  if sub.win and vim.api.nvim_win_is_valid(sub.win) then
    vim.api.nvim_win_close(sub.win, true)
  end
  sub.win = nil
end

--- Show `text` as a subtitle in a float along the bottom of the code window,
--- or close the float when `text` is nil or empty. The narrator calls this as
--- each sentence starts playing in the player, so it follows the voice rather
--- than the moment the audio was sent.
---
--- Over the code window rather than the bottom of the tab, which is where
--- Claude's terminal is: a float there would cover the prompt you type
--- questions into.
function M.subtitle(text)
  if text == nil or text == vim.NIL or vim.trim(text) == "" then
    close_subtitle()
    return "subtitle closed"
  end
  local win = code_window()
  last_win = win
  if not (sub.buf and vim.api.nvim_buf_is_valid(sub.buf)) then
    sub.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[sub.buf].bufhidden = "hide"
  end
  vim.api.nvim_buf_set_lines(sub.buf, 0, -1, false, { vim.trim(text) })

  -- Narrower than the window on a wide screen, since a line of 200 characters
  -- is hard to follow; the border takes two columns and two rows.
  local wwidth = vim.api.nvim_win_get_width(win)
  local wheight = vim.api.nvim_win_get_height(win)
  local width = math.max(10, math.min(wwidth - 4, 100))
  local config = {
    relative = "win", win = win,
    row = wheight - 3, col = math.floor((wwidth - width - 2) / 2),
    width = width, height = 1,
    anchor = "NW", style = "minimal", border = "rounded",
    focusable = false, zindex = 60, noautocmd = true,
  }
  -- The window it is anchored to may have changed since the last sentence (a
  -- new code window, a resize), so it is reconfigured every time.
  if sub.win and vim.api.nvim_win_is_valid(sub.win)
      and vim.api.nvim_win_get_tabpage(sub.win) == vim.api.nvim_win_get_tabpage(win) then
    vim.api.nvim_win_set_config(sub.win, config)
  else
    close_subtitle()
    sub.win = vim.api.nvim_open_win(sub.buf, false, config)
    vim.wo[sub.win].wrap = true
    vim.wo[sub.win].linebreak = true
    vim.wo[sub.win].winhighlight = "NormalFloat:WalkthroughSubtitle"
  end
  -- Grown to the wrapped text, at most a third of the window, and moved up by
  -- as much so its bottom edge stays on the window's last line.
  local rows = vim.api.nvim_win_text_height(sub.win, {}).all
  local height = math.max(1, math.min(rows, math.floor(wheight / 3)))
  config.height = height
  config.row = math.max(0, wheight - height - 2)
  vim.api.nvim_win_set_config(sub.win, config)
  return "subtitle shown"
end

--- Remove the walkthrough highlight from every buffer, and the subtitle.
function M.clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  close_subtitle()
  return "cleared"
end

-- What `:Walkthrough` asks of Claude. With the narrator, a tour: the stops go
-- to the narrator, which highlights each one here (calling show() over its own
-- connection) while speaking it. Claude adds stops in small batches as it
-- writes them, so playback starts early and Claude's thinking overlaps the
-- listening -- one stop per agent turn meant ~25 s of silence between stops.
-- Without the narrator, Claude moves the highlight itself through nvim-mcp
-- and writes the narration in chat.
--
-- `basis` is asked for because the narrator saves every tour under .tours/ to
-- be replayed later, and the line numbers only mean something against the
-- code they were written for. The narrator records the commit and which files
-- were modified on its own; what it cannot know is that the tour was about a
-- diff, a branch not checked out, or uncommitted work.
local function prompt(topic)
  return table.concat({
    "Give me a narrated walkthrough of " .. topic .. ".",
    "",
    "Use the `narrator` MCP server's tour tools; it speaks in my browser player and highlights each stop in my Neovim as it plays.",
    "",
    "1. Skim enough to outline 4 to 12 stops that tell the story of how it works, in order. Post the outline as one short list. Do not read everything first: playback should start soon.",
    "2. Call narrator `status`. If no player is connected, ask me to open the address that `./dev narrator-url` prints on the host, and wait until I say it is open.",
    "3. Call `tour_start` with project_root set to your working directory, a short title, and, if the line numbers do not simply refer to the checked-out commit, `basis` saying what they refer to (uncommitted changes, a diff between two revisions, and so on). The narrator saves the tour under .tours/ by itself; do not save it yourself.",
    "4. Write the first one or two stops and send them with `tour_add` at once; it returns immediately and they start playing. Then read on and keep adding stops one to three at a time, staying ahead of me. Each stop is a file path relative to project_root, first and last line (1-based, inclusive), a label of a few words, and one to four sentences of text.",
    "5. Write the text for the ear: no markdown, no symbols spelt out, say \"the setup function\" rather than reading identifiers character by character. Explain why as well as what.",
    "6. Mark the final batch with last=true, then call `tour_wait`.",
    "7. If any reply says I pressed Stop, stop adding and ask me what I would like. Answer in chat or with `speak`; to carry on, `tour_resume` then `tour_wait`. When the tour finishes, offer to go deeper on any stop.",
    "",
    "If the narrator tools are unavailable, use the `nvim` MCP server (nvim-mcp) instead: for each stop run `return require('walkthrough').show('<path>', <first>, <last>, '<label>')` with `exec_lua` and write the narration in chat; if it reports no connection, use `get_targets` and `connect` first. Finish with `return require('walkthrough').clear()`.",
  }, "\n")
end

-- What `:WalkthroughReplay` asks of Claude: one tool call, since the narrator
-- reads the saved file itself. Claude stays in the loop for Stop and questions,
-- which is what makes a replay more than a recording.
local function replay_prompt(file)
  return table.concat({
    "Replay the saved narrated walkthrough " .. file .. ".",
    "",
    "1. Call narrator `status`. If no player is connected, ask me to open the address that `./dev narrator-url` prints on the host, and wait until I say it is open.",
    "2. Call narrator `tour_replay` with path set to " .. vim.fn.fnamemodify(file, ":p") .. ", then `tour_wait`. If its reply says files have changed since the tour was saved, tell me which, briefly, but carry on.",
    "3. If a reply says I pressed Stop, ask me what I would like. Answer in chat or with `speak`; to carry on, `tour_resume` then `tour_wait`. Read the code a stop points at before answering questions about it.",
    "",
    "If the narrator tools are unavailable, read the file yourself and use the `nvim` MCP server (nvim-mcp) instead: for each stop run `return require('walkthrough').show('<path>', <first>, <last>, '<label>')` with `exec_lua` and write its text in chat; if it reports no connection, use `get_targets` and `connect` first. Finish with `return require('walkthrough').clear()`.",
  }, "\n")
end

-- A tab of its own, laid out like `nvim .`: the tree on the left and a code
-- window beside it, which show() drives, and Claude across the full width
-- underneath. A tab rather than splits in the current one, so the tour neither
-- squeezes nor takes over the windows you were working in, and `:tabclose`
-- puts everything back. The tree goes in before Claude's split: neo-tree opens
-- on the left at full height, so made the other way round it would cut
-- Claude's terminal short.
local function open_tab(file, argv)
  vim.cmd.tabnew()
  local code = vim.api.nvim_get_current_win()
  if file ~= "" then
    vim.cmd.edit(vim.fn.fnameescape(file))
  end
  pcall(vim.cmd, "Neotree show filesystem left")
  if vim.api.nvim_win_is_valid(code) then
    vim.api.nvim_set_current_win(code)
  end
  last_win = code
  vim.cmd("botright new")
  -- A quarter of the screen, but at least 20 rows for Claude's output, as long
  -- as that still leaves the code two thirds of it.
  local lines = vim.o.lines
  vim.api.nvim_win_set_height(0, math.max(math.floor(lines * 0.25), math.min(20, math.floor(lines / 3))))
  -- An argv list, not a shell string, so the prompt needs no quoting.
  vim.fn.jobstart(argv, { term = true })
  vim.cmd.startinsert()
  if file ~= "" then
    reveal_in_tree(code, vim.fn.fnamemodify(file, ":p"))
  end
end

local function have_claude()
  if vim.fn.executable("claude") == 0 then
    vim.notify("Walkthrough: claude is not on PATH", vim.log.levels.ERROR)
    return false
  end
  return true
end

-- `:Walkthrough [topic]`, or over a visual range, those lines of this file.
-- With neither, the current file.
function M.command(opts)
  if not have_claude() then return end
  -- Only a real file counts. Run from neo-tree, `%` is "neo-tree filesystem
  -- [1]", and Claude dutifully narrated neo-tree's filesystem source from the
  -- plugin directory instead of the project.
  local file = ""
  if vim.bo.buftype == "" and vim.fn.filereadable(vim.fn.expand("%:p")) == 1 then
    file = vim.fn.expand("%:.")
  end
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
  open_tab(file, { "claude", prompt(topic) })
end

-- Saved tours, newest first, as paths relative to the working directory.
local function saved_tours()
  local files = vim.fn.glob(".tours/*.json", false, true)
  table.sort(files, function(a, b) return vim.fn.getftime(a) > vim.fn.getftime(b) end)
  return files
end

-- `:WalkthroughReplay [file]`: a tour saved under .tours/, by default the
-- newest one.
function M.replay(opts)
  if not have_claude() then return end
  local file = opts.args
  if file == "" then
    file = saved_tours()[1] or ""
    if file == "" then
      vim.notify("WalkthroughReplay: no saved tours in .tours/", vim.log.levels.WARN)
      return
    end
  end
  if vim.fn.filereadable(file) == 0 then
    vim.notify("WalkthroughReplay: no such file: " .. file, vim.log.levels.ERROR)
    return
  end
  open_tab("", { "claude", replay_prompt(file) })
end

function M.setup()
  vim.api.nvim_create_user_command("Walkthrough", M.command, {
    nargs = "*",
    range = true,
    desc = "Narrated walkthrough by Claude Code (of a topic, a range, or this file)",
  })
  vim.api.nvim_create_user_command("WalkthroughReplay", M.replay, {
    nargs = "?",
    complete = function(lead)
      return vim.tbl_filter(function(f) return f:find(lead, 1, true) == 1 end, saved_tours())
    end,
    desc = "Replay a narrated walkthrough saved under .tours/",
  })
  vim.api.nvim_create_user_command("WalkthroughClear", function() M.clear() end,
    { desc = "Remove the walkthrough highlight and subtitle" })
end

return M
