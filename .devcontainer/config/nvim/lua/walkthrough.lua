-- Narrated code walkthroughs: the Neovim half.
--
-- show(), subtitle(), controls() and clear() are called over RPC, one stop
-- at a time, and diff_info() once as a tour starts:
--
--   require('walkthrough').show('/path/to/dev', 120, 148, 'Choosing a port')
--   require('walkthrough').subtitle('The port is chosen once, at setup...')
--   require('walkthrough').controls({ state = 'playing', index = 2, total = 6 })
--   require('walkthrough').clear()
--
-- by the narrator during a tour (narrator.py, over the socket the nvim-mcp
-- plugin opens), or by Claude Code through nvim-mcp's `exec_lua` when there is
-- no narrator. `:Walkthrough` starts a session in a tab of its own: the tree
-- on the left, the code window the tour drives on the right, and a Claude Code
-- terminal across the bottom, given a prompt that spells out the protocol.
-- Run from a `:DiffviewOpen` tab it stays in that tab instead and tours the
-- diff (diff mode, below).
-- `:WalkthroughReplay` does the same for a tour the narrator saved earlier
-- under .tours/, which Claude then only has to hand back to the narrator; a
-- tour of a diff reopens that diff, and files changed since are shown as the
-- tour's commit has them, from git (show()'s `source`).
-- `:WalkthroughReplayOffline` plays a saved tour with no Claude at all, and
-- `:WalkthroughControl` presses the player's buttons, which are also along
-- the bottom of the subtitle float. The
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
-- The subtitle's buttons, apart from `ns`, which clear_marks() empties in
-- every buffer at each stop.
local bar_ns = vim.api.nvim_create_namespace("walkthrough_bar")

-- Linked rather than coloured, so they follow the colorscheme. `default`
-- leaves a colorscheme free to style them properly.
vim.api.nvim_set_hl(0, "WalkthroughRange", { link = "Visual", default = true })
vim.api.nvim_set_hl(0, "WalkthroughLabel", { link = "Title", default = true })
vim.api.nvim_set_hl(0, "WalkthroughSubtitle", { link = "NormalFloat", default = true })
vim.api.nvim_set_hl(0, "WalkthroughButton", { link = "TabLine", default = true })
vim.api.nvim_set_hl(0, "WalkthroughCount", { link = "Comment", default = true })

-- The window the last stop was shown in, reused while it stays suitable so the
-- code does not hop between splits from one stop to the next. `:Walkthrough`
-- sets it to its tab's code window, and that one is kept even while you are in
-- another tab: the narrator calls show() whenever a stop starts, and taking
-- "this tab" at that moment would drag the tour into whatever you were doing
-- while it played.
local last_win = nil

-- The subtitle float and its buffer, reused from one sentence to the next.
-- `text` is the sentence being spoken, `bar` the tour's state as the narrator
-- last sent it to controls(), and `buttons` where the buttons on the float's
-- bottom row are, for the click handler (on_click).
local sub = { win = nil, buf = nil, text = nil, bar = nil, buttons = {}, bar_row = nil }

-- Diff mode: set when `:Walkthrough` starts in a Diffview tab, which it then
-- stays in instead of opening one of its own. The new tab would show files
-- from disk, without the diff the walkthrough was asked about, and for a diff
-- between two commits not even the right version of them. In diff mode a
-- stop in one of the diff's files selects that file in Diffview and
-- highlights its right-hand side; a stop anywhere else opens in `peek`, a
-- float over that side, so Diffview's own windows keep their buffers.
-- Diffview can only switch files while its tab is on screen (it cancels the
-- swap otherwise), so a stop that arrives while you are elsewhere waits in
-- `pending` until you return to the tab.
local diff = nil      -- { view = <DiffView>, tab = <tabpage> }
local peek = nil      -- window id of the float
local pending = nil   -- { path, first, last, label }

local function is_code_window(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  if vim.api.nvim_win_get_config(win).relative ~= "" then return false end
  -- buftype "" is an ordinary file buffer: not a terminal (possibly the one
  -- Claude is running in), not neo-tree, not help, not a quickfix list. A
  -- file shown from git (source_buffer) is code too.
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == "" or vim.b[buf].walkthrough_source ~= nil
end

-- The Diffview tab's view in diff mode, while that view is still open. A
-- closed view ends diff mode, and the tour carries on the ordinary way.
local function diff_view()
  if not diff then return nil end
  local lib = package.loaded["diffview.lib"]
  if lib and vim.api.nvim_tabpage_is_valid(diff.tab)
      and lib.tabpage_to_view(diff.tab) == diff.view then
    return diff.view
  end
  diff, pending = nil, nil
  return nil
end

-- The window of Diffview's that shows the right-hand side, the newer version.
local function diff_main_win(view)
  local ok, win = pcall(function() return view.cur_layout:get_main_win().id end)
  if ok and win and vim.api.nvim_win_is_valid(win) then return win end
  return nil
end

local function close_peek()
  if peek and vim.api.nvim_win_is_valid(peek) then
    vim.api.nvim_win_close(peek, true)
  end
  peek = nil
end

-- The previous stop's window, else the largest code window in this tab, else a
-- new split. The split is made without moving focus, so typing into Claude's
-- terminal is never interrupted. In diff mode, the float if a stop outside the
-- diff is open, else the diff's right-hand side.
local function code_window()
  if diff_view() then
    if peek and vim.api.nvim_win_is_valid(peek) then return peek end
    local win = diff_main_win(diff.view)
    if win then return win end
  end
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

-- Clicks on the subtitle's buttons, watched with vim.on_key while the float
-- has them. Not a <LeftMouse> mapping: satellite.nvim (the scrollbar) maps
-- <LeftMouse> globally, and its handler re-sends the click and reads the
-- input stream itself, so it could neither stay mapped beside ours nor be
-- called from inside an expr mapping. on_key sees every key without taking
-- the mapping, and since Neovim 0.11 can swallow one by returning "". A
-- press on a button runs it; a click anywhere else on the float is swallowed
-- too, rather than moving the cursor into it; every other click goes on as
-- usual. getmousepos() reports only focusable floats, so the subtitle is
-- focusable (and so reachable with <C-w>w too, a small price).
--
-- In Claude's terminal a click reaches Neovim only while Claude has not
-- turned on mouse reporting; otherwise the terminal gets it (see
-- :help terminal-mouse), and the player's buttons or :WalkthroughControl do
-- the same job.
local click_ns = vim.api.nvim_create_namespace("walkthrough_click")
local clicks_on = false
local PRESS = vim.keycode("<LeftMouse>")
local FOLLOW = { vim.keycode("<LeftRelease>"), vim.keycode("<LeftDrag>") }

local function on_key(_, typed)
  if not (typed and typed ~= "" and sub.win) then return end
  local press = typed:find(PRESS, 1, true) ~= nil
  if not press and not (typed:find(FOLLOW[1], 1, true) or typed:find(FOLLOW[2], 1, true)) then
    return
  end
  local pos = vim.fn.getmousepos()
  if pos.winid ~= sub.win then return end
  if press and pos.line == sub.bar_row then
    for _, b in ipairs(sub.buttons) do
      if pos.column >= b.from and pos.column <= b.to then
        vim.schedule(function() M.control(b.action) end)
        break
      end
    end
  end
  return ""
end

local function watch_clicks(on)
  if on == clicks_on then return end
  clicks_on = on
  vim.on_key(on and on_key or nil, click_ns)
end

local function close_subtitle()
  if sub.win and vim.api.nvim_win_is_valid(sub.win) then
    vim.api.nvim_win_close(sub.win, true)
  end
  sub.win = nil
  watch_clicks(false)
end

local function clear_marks()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
end

-- Highlight and scroll to the range in the buffer `win` shows.
local function mark(win, first, last, label)
  local buf = vim.api.nvim_win_get_buf(win)
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
    -- A diff window folds the lines around each change, so a stop on context
    -- lines would be hidden in a fold. pcall because a range with no fold in
    -- it is an error (E490).
    pcall(vim.cmd, string.format("%d,%dfoldopen!", first, last))
    -- topfill = 1 keeps the label's virtual line visible when the range starts
    -- at the very top of the window.
    vim.fn.winrestview({ topline = top, topfill = label and 1 or 0, lnum = first, col = 0 })
  end)
  return first, last
end

-- The narrator passes a `source` ({rev, top, rel}) when a stop's code is to
-- come from git rather than disk: a replay of a tour whose files have changed
-- since, or a stop outside the diff in a tour of a diff between commits. nil
-- arrives as vim.NIL when it comes over RPC.
local function no_source(source)
  return source == nil or source == vim.NIL
end

-- A read-only buffer holding `git show <rev>:<rel>`, named after both, made
-- once and kept for later stops in the same file. Not a file on disk, so
-- nothing can write it back over the current version by mistake, and the
-- language server leaves it alone; the filetype still gives it treesitter
-- highlighting.
local function source_buffer(source)
  local name = string.format("walkthrough://%s/%s", source.rev:sub(1, 12), source.rel)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == name and vim.api.nvim_buf_is_loaded(buf) then
      return buf, name
    end
  end
  local r = vim.system({ "git", "-C", source.top, "show", source.rev .. ":" .. source.rel },
    { text = true }):wait()
  if r.code ~= 0 then
    error(string.format("walkthrough: git show %s:%s failed: %s",
      source.rev:sub(1, 12), source.rel, vim.trim(r.stderr or "")))
  end
  local text = r.stdout:gsub("\n$", "")
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.b[buf].walkthrough_source = source.rev
  local ft = vim.filetype.match({ buf = buf, filename = source.rel })
  if ft then vim.bo[buf].filetype = ft end
  return buf, name
end

-- Edit `abs` into `win` unless it already shows it, or with a `source`, put
-- the file as git has it there instead. Returns the name to report.
local function edit_into(win, abs, source)
  if not no_source(source) then
    local buf, name = source_buffer(source)
    if vim.api.nvim_win_get_buf(win) ~= buf then
      vim.api.nvim_win_set_buf(win, buf)
    end
    return name
  end
  vim.api.nvim_win_call(win, function()
    if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p") ~= abs then
      vim.cmd.edit(vim.fn.fnameescape(abs))
    end
  end)
  return vim.fn.fnamemodify(abs, ":~:.")
end

local function showing(name, first, last)
  return string.format("showing %s:%d-%d", name, first, last)
end

-- The diff's entry for `abs`, matched on its path at the right-hand side's
-- revision. The default `:DiffviewOpen` lists a file twice when it has both
-- staged and unstaged changes; the unstaged entry wins, since its right-hand
-- side is the file on disk, which is what Claude most likely read.
local function diff_entry(view, abs)
  local found
  for _, entry in view.files:iter() do
    if vim.fn.fnamemodify(entry.absolute_path, ":p") == abs then
      if entry.kind ~= "staged" then return entry end
      found = found or entry
    end
  end
  return found
end

-- A float over the diff's right-hand side, for a stop outside the diff: a
-- file of the project the change touches without changing it, say. Over the
-- side rather than in a split, because Diffview owns its tab's layout and
-- rebuilds it when a file is selected, and a float leaves it nothing to
-- rebuild. `relative = "win"` puts it in the Diffview tab even when another
-- tab is on screen.
local function peek_window(view, abs)
  local anchor = diff_main_win(view)
  if not anchor then return nil end
  local config = {
    relative = "win", win = anchor, row = 0, col = 0,
    width = math.max(10, vim.api.nvim_win_get_width(anchor) - 2),
    height = math.max(3, vim.api.nvim_win_get_height(anchor) - 2),
    border = "rounded", title = " " .. vim.fn.fnamemodify(abs, ":~:.") .. " (not in the diff) ",
    title_pos = "center", zindex = 50, noautocmd = true,
  }
  if peek and vim.api.nvim_win_is_valid(peek)
      and vim.api.nvim_win_get_tabpage(peek) == vim.api.nvim_win_get_tabpage(anchor) then
    vim.api.nvim_win_set_config(peek, config)
  else
    close_peek()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].bufhidden = "wipe"
    peek = vim.api.nvim_open_win(scratch, false, config)
    -- A new window copies the current one's options, which during a tour is
    -- Claude's terminal; take the code window's instead.
    for _, opt in ipairs({ "number", "relativenumber", "signcolumn", "wrap", "cursorline" }) do
      vim.wo[peek][opt] = vim.wo[anchor][opt]
    end
  end
  return peek
end

-- A stop outside the diff comes with a `source` (the right-hand commit) in a
-- tour of a diff between commits, so the float shows that version even when
-- the checkout is neither side.
local function show_in_diff(view, path, abs, first, last, label, source)
  local entry = diff_entry(view, abs)
  if not entry then
    if no_source(source) and vim.fn.filereadable(abs) == 0 then
      error("walkthrough: no such file: " .. path)
    end
    pending = nil
    local win = peek_window(view, abs)
    if not win then error("walkthrough: the Diffview tab has no diff window") end
    local name = edit_into(win, abs, source)
    return showing(name, mark(win, first, last, label))
  end
  close_peek()
  if vim.api.nvim_get_current_tabpage() ~= diff.tab then
    pending = { path, first, last, label, source }
    return string.format("%s:%d-%d will be shown when the Diffview tab is on screen",
      vim.fn.fnamemodify(abs, ":~:."), first, last)
  end
  pending = nil
  -- Selecting a file is asynchronous in Diffview (it may fetch blobs from git),
  -- so the highlight is placed once the selection is done, and after anything
  -- Diffview scheduled on the way, such as restoring the cursor it last had
  -- in that file. The narrator does not wait for the result.
  local async = require("diffview.async")
  async.void(function()
    async.await(view:set_file(entry, false))
    async.await(async.scheduler())
    if diff_view() ~= view or view.cur_entry ~= entry then return end
    local win = diff_main_win(view)
    if win then
      clear_marks()
      mark(win, first, last, label)
    end
  end)()
  return string.format("showing %s:%d-%d in the diff", vim.fn.fnamemodify(abs, ":~:."), first, last)
end

--- Show lines `first`..`last` (1-based, inclusive) of `path`, highlighted, with
--- an optional `label` above them. Clears the previous stop's highlight.
--- `path` is relative to Neovim's working directory, or absolute. In diff mode
--- the lines are those of the diff's right-hand side. With `source`
--- ({rev, top, rel}, from the narrator) the file is shown as commit `rev` has
--- it rather than from disk.
local render

local function show_stop(path, first, last, label, source)
  local abs = vim.fn.fnamemodify(path, ":p")
  local view = diff_view()
  if view then
    return show_in_diff(view, path, abs, first, last, label, source)
  end
  local win = code_window()
  last_win = win
  if no_source(source) and vim.fn.filereadable(abs) == 0 then
    error("walkthrough: no such file: " .. path)
  end
  local name = edit_into(win, abs, source)
  first, last = mark(win, first, last, label)
  if vim.fn.filereadable(abs) == 1 then reveal_in_tree(win, abs) end
  return showing(name, first, last)
end

function M.show(path, first, last, label, source)
  clear_marks()
  -- The last stop's sentence goes; the buttons stay, moved to the new window.
  sub.text = nil
  local ok, res = pcall(show_stop, path, first, last, label, source)
  render()
  if not ok then error(res, 0) end
  return res
end

-- The bottom row of the subtitle: the buttons, and how far the tour has got.
-- Records each button's byte columns (1-based, as getmousepos() counts them).
-- Plain geometric glyphs rather than the media-control ones (U+23EE and
-- friends), which some terminals draw two cells wide and so misalign.
local function bar_line(bar, width)
  local buttons = {
    { "◀ Prev", "prev" },
    bar.state == "stopped" and { "▶ Continue", "continue" } or { "■ Stop", "stop" },
    { "Next ▶", "next" },
  }
  local line, ranges = " ", {}
  for i, b in ipairs(buttons) do
    if i > 1 then line = line .. "   " end
    local label = " " .. b[1] .. " "
    table.insert(ranges, { from = #line + 1, to = #line + #label, action = b[2] })
    line = line .. label
  end
  local count = string.format("%d/%d%s ", math.min(bar.index + 1, bar.total), bar.total,
    bar.complete and "" or "…")
  local pad = width - vim.fn.strdisplaywidth(line) - vim.fn.strdisplaywidth(count)
  local count_from = #line + math.max(1, pad)
  return line .. string.rep(" ", math.max(1, pad)) .. count, ranges, count_from
end

local function bar_visible()
  local bar = sub.bar
  return bar ~= nil and (bar.state == "playing" or bar.state == "stopped") and (bar.total or 0) > 0
end

-- Draw the subtitle float from `sub`: the sentence, if one is being spoken,
-- over the buttons, while a tour is playing or stopped. With neither, close
-- it. After Stop there is no sentence, but the row stays, for Continue.
function render()
  local has_bar = bar_visible()
  if not sub.text and not has_bar then
    close_subtitle()
    return
  end
  local win = code_window()
  if not diff_view() then last_win = win end
  if not (sub.buf and vim.api.nvim_buf_is_valid(sub.buf)) then
    sub.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[sub.buf].bufhidden = "hide"
  end

  -- Narrower than the window on a wide screen, since a line of 200 characters
  -- is hard to follow; the border takes two columns and two rows.
  local wwidth = vim.api.nvim_win_get_width(win)
  local wheight = vim.api.nvim_win_get_height(win)
  local width = math.max(10, math.min(wwidth - 4, 100))
  local lines, count_from = {}, nil
  if sub.text then table.insert(lines, sub.text) end
  sub.buttons, sub.bar_row = {}, nil
  if has_bar then
    local row
    row, sub.buttons, count_from = bar_line(sub.bar, width)
    table.insert(lines, row)
    sub.bar_row = #lines
  end
  vim.bo[sub.buf].modifiable = true
  vim.api.nvim_buf_set_lines(sub.buf, 0, -1, false, lines)
  vim.bo[sub.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(sub.buf, bar_ns, 0, -1)
  for _, b in ipairs(sub.buttons) do
    vim.api.nvim_buf_set_extmark(sub.buf, bar_ns, sub.bar_row - 1, b.from - 1,
      { end_col = b.to, hl_group = "WalkthroughButton" })
  end
  if count_from then
    vim.api.nvim_buf_set_extmark(sub.buf, bar_ns, sub.bar_row - 1, count_from - 1,
      { end_col = #lines[sub.bar_row], hl_group = "WalkthroughCount" })
  end

  local config = {
    relative = "win", win = win,
    row = wheight - 3, col = math.floor((wwidth - width - 2) / 2),
    width = width, height = 1,
    anchor = "NW", style = "minimal", border = "rounded",
    focusable = true, zindex = 60, noautocmd = true,
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
  watch_clicks(has_bar)
end

--- Show `text` as a subtitle in a float along the bottom of the code window,
--- or take it away when `text` is nil or empty (the float itself stays while
--- it has buttons). The narrator calls this as each sentence starts playing
--- in the player, so it follows the voice rather than the moment the audio
--- was sent.
---
--- Over the code window rather than the bottom of the tab, which is where
--- Claude's terminal is: a float there would cover the prompt you type
--- questions into.
function M.subtitle(text)
  if text == nil or text == vim.NIL or vim.trim(text) == "" then
    sub.text = nil
  else
    sub.text = vim.trim(text)
  end
  render()
  return sub.text and "subtitle shown" or "subtitle closed"
end

--- The tour's state, for the buttons along the bottom of the subtitle:
--- { state = "playing"|"stopped"|"finished", index = <0-based stop>,
---   total = <stops queued>, complete = <all stops sent> }. The narrator calls
--- it whenever one of these changes; "finished" takes the buttons away.
function M.controls(state)
  if type(state) ~= "table" or state.state == "finished" then
    sub.bar = nil
  else
    sub.bar = {
      state = state.state,
      index = tonumber(state.index) or 0,
      total = tonumber(state.total) or 0,
      complete = state.complete == true,
    }
  end
  render()
  return "controls updated"
end

--- Press one of the player's buttons: "prev", "next", "stop" or "continue".
--- Through `narrator control`, which knows the narrator's port and token.
function M.control(action)
  if vim.fn.executable("narrator") == 0 then
    vim.notify("Walkthrough: the narrator is not installed here", vim.log.levels.ERROR)
    return
  end
  vim.system({ "narrator", "control", action }, { text = true }, function(r)
    if r.code ~= 0 then
      vim.schedule(function()
        vim.notify("Walkthrough: narrator control " .. action .. " failed: "
          .. vim.trim((r.stderr or "") .. (r.stdout or "")), vim.log.levels.ERROR)
      end)
    end
  end)
end

--- What diff mode is touring, for the narrator to record with a saved tour:
--- nil outside diff mode, else each side as a full commit hash, "worktree" or
--- "index", and the diff's path arguments.
function M.diff_info()
  local view = diff_view()
  if not view then return nil end
  local RevType = require("diffview.vcs.rev").RevType
  local function side(rev)
    if rev.type == RevType.COMMIT and rev.commit then return rev.commit end
    if rev.type == RevType.STAGE then return "index" end
    return "worktree"
  end
  return {
    left = side(view.left),
    right = side(view.right),
    paths = view.path_args or {},
    rev_arg = view.rev_arg,
  }
end

--- Remove the walkthrough highlight from every buffer, the subtitle, and in
--- diff mode the float for stops outside the diff.
function M.clear()
  clear_marks()
  sub.text, sub.bar = nil, nil
  close_subtitle()
  close_peek()
  pending = nil
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
-- The narrator saves a tour under .tours/ only when git can give back the code
-- it narrates: files committed and unchanged at HEAD, or a diff between two
-- commits. For an ordinary tour only Claude knows which files it will
-- narrate, so it is asked to check them and to ask before narrating
-- uncommitted work, so that the listener knows the tour will not be kept. In
-- diff mode `M.command` asks instead, before Claude starts, as the sides of
-- the diff say it all; `context` is then given, and the step is left out.
--
-- `context`, if given, is a paragraph placed after the first line: in diff
-- mode, what the diff is (diff_context). `first_step`, if given, replaces
-- step 1, which is how a deep tour (deep_step) asks for reading first.
local function prompt(topic, context, first_step)
  local lines = {
    "Give me a narrated walkthrough of " .. topic .. ".",
    "",
  }
  if context then
    vim.list_extend(lines, { context, "" })
  end
  local steps = {
    first_step or "Skim enough to outline 4 to 12 stops that tell the story of how it works, in order. Post the outline as one short list. Do not read everything first: playback should start soon.",
  }
  if not context then
    table.insert(steps, "Run `git status --porcelain --` with the files your stops will be in. If any of them is untracked or has uncommitted changes, name them, tell me the walkthrough involves uncommitted work and so the narrator will not save it for replay, and wait until I say to go ahead. Uncommitted changes in other files do not matter.")
  end
  vim.list_extend(steps, {
    "Call narrator `status`. If no player is connected, ask me to open the address that `./dev narrator-url` prints on the host, and wait until I say it is open.",
    "Call `tour_start` with project_root set to your working directory, a short title, and optionally `basis`, one sentence on what the tour covers. The narrator saves the tour under .tours/ by itself, when the code it narrates is committed; do not save it yourself.",
    "Write the first one or two stops and send them with `tour_add` at once; it returns immediately and they start playing. Then read on and keep adding stops one to three at a time, staying ahead of me. Each stop is a file path relative to project_root, first and last line (1-based, inclusive), a label of a few words, and one to four sentences of text.",
    "Write the text for the ear: no markdown, no symbols spelt out, say \"the setup function\" rather than reading identifiers character by character. Explain why as well as what.",
    "Mark the final batch with last=true, then call `tour_wait`.",
    "If any reply says I pressed Stop, stop adding and ask me what I would like. Answer in chat or with `speak`; to carry on, `tour_resume` then `tour_wait`. When the tour finishes, offer to go deeper on any stop.",
  })
  vim.list_extend(lines, {
    "Use the `narrator` MCP server's tour tools; it speaks in my browser player and highlights each stop in my Neovim as it plays.",
    "",
  })
  for i, step in ipairs(steps) do
    -- deep_step comes numbered, from when the steps were a fixed list.
    table.insert(lines, i .. ". " .. (step:gsub("^%d+%. ", "")))
  end
  vim.list_extend(lines, {
    "",
    "If the narrator tools are unavailable, use the `nvim` MCP server (nvim-mcp) instead: for each stop run `return require('walkthrough').show('<path>', <first>, <last>, '<label>')` with `exec_lua` and write the narration in chat; if it reports no connection, use `get_targets` and `connect` first. Finish with `return require('walkthrough').clear()`.",
  })
  return table.concat(lines, "\n")
end

-- What `:WalkthroughReplay` asks of Claude: one tool call, since the narrator
-- reads the saved file itself. Claude stays in the loop for Stop and questions,
-- which is what makes a replay more than a recording.
local function replay_prompt(file)
  return table.concat({
    "Replay the saved narrated walkthrough " .. file .. ".",
    "",
    "1. Call narrator `status`. If no player is connected, ask me to open the address that `./dev narrator-url` prints on the host, and wait until I say it is open.",
    "2. Call narrator `tour_replay` with path set to " .. vim.fn.fnamemodify(file, ":p") .. ", then `tour_wait`. If its reply says files are shown from git because they have changed since, tell me which, briefly, but carry on.",
    "3. If a reply says I pressed Stop, ask me what I would like. Answer in chat or with `speak`; to carry on, `tour_resume` then `tour_wait`. Read the code a stop points at before answering questions about it, as the tour's commit has it (`git show <commit>:<path>`) when the reply said it is shown from git, or for a diff tour at its right-hand commit.",
    "",
    "If the narrator tools are unavailable, read the file yourself and use the `nvim` MCP server (nvim-mcp) instead: for each stop run `return require('walkthrough').show('<path>', <first>, <last>, '<label>')` with `exec_lua` and write its text in chat; if it reports no connection, use `get_targets` and `connect` first. Finish with `return require('walkthrough').clear()`.",
  }, "\n")
end

-- Claude's terminal across the full width at the bottom of the current tab.
-- 'winfixheight' because Diffview equalises its tab's windows when it swaps
-- layouts, which would take Claude's rows for the diff.
local function open_terminal(argv)
  vim.cmd("botright new")
  -- A quarter of the screen, but at least 20 rows for Claude's output, as long
  -- as that still leaves the code two thirds of it.
  local lines = vim.o.lines
  vim.api.nvim_win_set_height(0, math.max(math.floor(lines * 0.25), math.min(20, math.floor(lines / 3))))
  vim.wo.winfixheight = true
  -- An argv list, not a shell string, so the prompt needs no quoting.
  vim.fn.jobstart(argv, { term = true })
  vim.cmd.startinsert()
end

-- A tab of its own, laid out like `nvim .`: the tree on the left and a code
-- window beside it, which show() drives, and Claude across the full width
-- underneath (no Claude for an offline replay, with `argv` nil). A tab rather than splits in the current one, so the tour neither
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
  if argv then open_terminal(argv) end
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

-- The Diffview view of the current tab, if it is a `:DiffviewOpen` diff (not
-- file history, whose files change with the commit you select). Looked up in
-- package.loaded so that a session that never opened Diffview does not load
-- it here.
local function current_diff_view()
  local lib = package.loaded["diffview.lib"]
  if not lib then return nil end
  local view = lib.get_current_view()
  local ok, is_diff = pcall(function()
    return view:instanceof(require("diffview.scene.views.diff.diff_view").DiffView)
  end)
  return ok and is_diff and view or nil
end

-- Start diff mode in `view`'s tab, or end it with nil.
local function set_diff(view)
  close_peek()
  pending = nil
  diff = view and { view = view, tab = vim.api.nvim_get_current_tabpage() } or nil
end

-- A paragraph telling Claude what the diff in the Diffview tab is: the git
-- command that prints it, what each side holds, and its files, which in the
-- default `:DiffviewOpen` include untracked ones that `git diff` leaves out.
--
-- When both sides are commits, it also says whether the checkout is one of
-- them. A file the diff does not touch is the same on both sides, so Claude
-- reading it from disk is right whenever the checkout is either side; with
-- `:DiffviewOpen v1.0..v2.0` on main it is neither, and Claude would read
-- code from main without any sign that it was the wrong code. The same goes
-- for CLAUDE.md, which Claude Code loads from the working directory at start,
-- so from the checkout, whatever the diff is between.
local function short(h) return h and h:sub(1, 12) or "?" end

local function diff_context(view)
  local RevType = require("diffview.vcs.rev").RevType
  local function side(rev)
    if rev.type == RevType.LOCAL then return "the working tree (the files on disk)" end
    if rev.type == RevType.STAGE then return "the index (read a file with `git show :<path>`)" end
    return string.format("commit %s (read a file with `git show %s:<path>`)", short(rev.commit), short(rev.commit))
  end
  local ok, args = pcall(function() return view.adapter:rev_to_args(view.left, view.right) end)
  local cmd = "git diff"
  if ok and args then
    for _, a in ipairs(args) do
      -- Full hashes shortened, for a prompt that stays readable.
      cmd = cmd .. " " .. a:gsub("%x+", function(h) if #h >= 40 then return h:sub(1, 12) end end)
    end
  end
  if view.path_args and #view.path_args > 0 then
    cmd = cmd .. " -- " .. table.concat(view.path_args, " ")
  end
  local out = {
    string.format("It is about the diff open in my Diffview tab (`:DiffviewOpen%s`): `%s`.",
      view.rev_arg and (" " .. view.rev_arg) or "", cmd),
    "Its left side is " .. side(view.left) .. ", its right side " .. side(view.right) .. ".",
  }
  local files, n = {}, 0
  for _, e in view.files:iter() do
    n = n + 1
    if n <= 60 then
      local name = e.oldpath and (e.oldpath .. " -> " .. e.path) or e.path
      local status = e.status == "?" and "untracked" or (e.status or "?")
      table.insert(files, string.format("%s %s%s", status, name,
        e.kind == "staged" and " (staged: HEAD against the index)" or ""))
    end
  end
  if n > 60 then table.insert(files, string.format("... and %d more", n - 60)) end
  if n > 0 then
    table.insert(out, "Its files: " .. table.concat(files, "; ") .. ".")
  end
  if view.left.type == RevType.COMMIT and view.right.type == RevType.COMMIT then
    local top = view.adapter.ctx.toplevel
    local head = vim.trim(vim.fn.system({ "git", "-C", top, "rev-parse", "HEAD" }))
    local dirty = vim.trim(vim.fn.system({ "git", "-C", top, "status", "--porcelain", "--untracked-files=no" })) ~= ""
    local but = dirty and ", apart from my uncommitted changes" or ""
    if head == view.right.commit then
      table.insert(out, "My checkout is the right side's commit, so the files on disk are the right side" .. but .. ".")
    elseif head == view.left.commit then
      table.insert(out, "My checkout is the left side's commit, so the files on disk are the left side" .. but .. ".")
    else
      table.insert(out, string.format("My checkout (%s) is neither side, so the files on disk match neither: read and search the code only through git at the side's commit (`git show <commit>:<path>`, `git grep <pattern> <commit>`), never on disk. The project's CLAUDE.md you were given is the checkout's too, so check what it says against the sides before relying on it.", short(head)))
    end
  end
  table.insert(out, "Give each stop's lines as numbered on the right-hand side, the new version: a stop in one of these files opens it in the diff, with its old version beside it, and a stop in any other file opens in a float over the diff, so keep most stops in the diff's files. Removed lines cannot be highlighted; talk about them at the lines that replaced them, or at the nearest lines kept. Pass `basis` to `tour_start`, saying what the diff is.")
  return table.concat(out, " ")
end

-- Step 1 for a deep tour of a diff (`:Walkthrough!`): read the code as it
-- was before outlining anything. The ordinary step 1 skims so that playback
-- starts within seconds, and Claude then narrates mostly from the hunks, with
-- their three lines of context: it never sees what a changed function did
-- before, or what calls it. That costs a wait, tens of seconds to minutes
-- with the size of the change, so it is asked for rather than the default.
--
-- The README is asked for too, as background: Claude Code loads CLAUDE.md by
-- itself (from the working directory and its parents) but not the README, and
-- a project's README says what the code is for, which a diff never does. It is
-- named as it is at the left revision, since a tour of an old range may come
-- from before a rename or before the README existed.
local function readme_at(top, commit)
  local names
  if commit then
    names = vim.fn.systemlist({ "git", "-C", top, "ls-tree", "--name-only", commit })
    if vim.v.shell_error ~= 0 then names = {} end
  else
    names = vim.tbl_map(function(f) return vim.fn.fnamemodify(f, ":t") end,
      vim.fn.glob(top .. "/README*", false, true))
  end
  for _, want in ipairs({ "README.md", "README.rst", "README.txt", "README" }) do
    if vim.tbl_contains(names, want) then return want end
  end
  for _, n in ipairs(names) do
    if n:match("^README") then return n end
  end
  return nil
end

local function deep_step(view)
  local RevType = require("diffview.vcs.rev").RevType
  local rev = view.left
  local read, search, readme
  local top = view.adapter.ctx.toplevel
  if rev.type == RevType.COMMIT then
    read = string.format("`git show %s:<path>`", short(rev.commit))
    search = string.format("`git grep -n <pattern> %s`", short(rev.commit))
    readme = readme_at(top, rev.commit)
    readme = readme and string.format("`git show %s:%s`", short(rev.commit), readme)
  elseif rev.type == RevType.STAGE then
    read, search = "`git show :<path>`", "`git grep -n --cached <pattern>`"
    readme = readme_at(top, nil)
    readme = readme and string.format("`git show :%s`", readme)
  else
    read, search = "the files on disk", "an ordinary search"
    readme = readme_at(top, nil)
  end
  local first = readme
    and ("First read the project's README for what the project is for (" .. readme .. ", as it was before the change), then the whole diff.")
    or "First read the whole diff."
  return "1. This is a deep tour: read before you outline, even though playback starts later. " .. first .. " Then read each changed file in full as it is on the left side, before the change (" .. read .. "), and the code that the changed parts call and the code that calls them, also on the left side (" .. search .. "), until you know how this worked before the change and what depends on it. Then outline 4 to 12 stops that tell the story of the change, in order, and post the outline as one short list. In the narration, say how each part worked before, what the change does to it, and why, and mention code outside the diff that the change affects."
end

-- `:Walkthrough [topic]`, or over a visual range, those lines of this file.
-- With neither, the current file. In a Diffview tab: the diff, in that tab,
-- and with a bang, a deep tour of it.
function M.command(opts)
  if not have_claude() then return end
  local view = current_diff_view()
  if opts.bang and not view then
    vim.notify("Walkthrough!: a deep tour is for a diff; run it in a :DiffviewOpen tab. Starting an ordinary one.",
      vim.log.levels.WARN)
  end
  if view then
    -- A diff with the working tree or the index on either side is of work
    -- git cannot give back later, so the narrator will not save the tour.
    -- Said before Claude starts, rather than discovered afterwards.
    local RevType = require("diffview.vcs.rev").RevType
    if view.left.type ~= RevType.COMMIT or view.right.type ~= RevType.COMMIT then
      local choice = vim.fn.confirm(
        "This diff includes uncommitted changes, so the walkthrough will not be saved for replay. Continue?",
        "&Yes\n&No", 2)
      if choice ~= 1 then return end
    end
    set_diff(view)
    local topic
    if opts.args ~= "" then
      topic = opts.args
    elseif opts.range > 0 and diff_main_win(view) == vim.api.nvim_get_current_win() and view.cur_entry then
      topic = string.format("lines %d to %d of the right-hand side of %s in this diff",
        opts.line1, opts.line2, view.cur_entry.path)
    else
      topic = "the changes in this diff"
    end
    open_terminal({ "claude", prompt(topic, diff_context(view), opts.bang and deep_step(view) or nil) })
    return
  end
  set_diff(nil)
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

-- The tour file `file` decoded, or nil and an error message.
local function read_tour(file)
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"), { luanil = { object = true } })
  end)
  if not ok or type(data) ~= "table" or type(data.stops) ~= "table" then
    return nil, "not a saved tour: " .. file
  end
  return data
end

-- The current tab's Diffview view if it shows commits `left`..`right`.
local function diff_between(left, right)
  local view = current_diff_view()
  if view and view.left.commit == left and view.right.commit == right then return view end
  return nil
end

-- Set up the screen for replaying `data`, with Claude's terminal running
-- `argv` across the bottom, or none for an offline replay. A tour of a diff
-- between two commits opens that diff in Diffview, as it was toured, rather
-- than whatever diff tab is on screen; any other tour gets a tab of its own
-- (open_tab). Calls `ready(view)` once the stops can be shown, which for a
-- diff is once Diffview has listed its files: until then a stop in one of
-- them would not find its entry and would open in the float instead.
local function prepare_replay(data, argv, ready)
  local d = data.diff
  if type(d) ~= "table" or type(d.left) ~= "string" or type(d.right) ~= "string" then
    set_diff(nil)
    open_tab("", argv)
    return ready(nil)
  end
  local view = diff_between(d.left, d.right)
  if not view then
    local cmd = { "DiffviewOpen" }
    if type(data.project_root) == "string" and vim.fn.isdirectory(data.project_root) == 1 then
      table.insert(cmd, "-C" .. vim.fn.fnameescape(data.project_root))
    end
    table.insert(cmd, d.left .. ".." .. d.right)
    if type(d.paths) == "table" and #d.paths > 0 then
      table.insert(cmd, "--")
      for _, p in ipairs(d.paths) do table.insert(cmd, vim.fn.fnameescape(p)) end
    end
    local ok, err = pcall(vim.cmd, table.concat(cmd, " "))
    view = ok and current_diff_view() or nil
    if not view then
      vim.notify("Walkthrough: could not open the tour's diff (" .. (err or table.concat(cmd, " ")) .. ")",
        vim.log.levels.ERROR)
      return
    end
  end
  set_diff(view)
  if argv then open_terminal(argv) end
  local deadline = vim.uv.now() + 10000
  local function poll()
    local listed = pcall(function() return view.files:len() > 0 end) and view.files:len() > 0
    if listed or view.initialized or vim.uv.now() > deadline then
      return ready(view)
    end
    vim.defer_fn(poll, 100)
  end
  poll()
end

-- The tour file `opts.args` names, else the newest under .tours/; nil after
-- telling the user why there is none.
local function tour_arg(opts, cmd)
  local file = opts.args
  if file == "" then
    file = saved_tours()[1] or ""
    if file == "" then
      vim.notify(cmd .. ": no saved tours in .tours/", vim.log.levels.WARN)
      return nil
    end
  end
  if vim.fn.filereadable(file) == 0 then
    vim.notify(cmd .. ": no such file: " .. file, vim.log.levels.ERROR)
    return nil
  end
  local data, err = read_tour(file)
  if not data then
    vim.notify(cmd .. ": " .. err, vim.log.levels.ERROR)
    return nil
  end
  return vim.fn.fnamemodify(file, ":p"), data
end

-- `:WalkthroughReplay [file]`: a tour saved under .tours/, by default the
-- newest one, with Claude there for questions.
function M.replay(opts)
  if not have_claude() then return end
  local file, data = tour_arg(opts, "WalkthroughReplay")
  if not file then return end
  prepare_replay(data, { "claude", replay_prompt(file) }, function() end)
end

-- What `narrator replay` said, as one notification.
local function report_replay(r)
  local ok, reply = pcall(vim.json.decode, r.stdout or "", { luanil = { object = true } })
  if r.code ~= 0 or not ok or type(reply) ~= "table" or not reply.ok then
    local why = ok and type(reply) == "table" and reply.error
      or vim.trim((r.stderr or "") .. (r.stdout or ""))
    vim.notify("WalkthroughReplayOffline: " .. (why ~= "" and why or "narrator replay failed"),
      vim.log.levels.ERROR)
    return
  end
  local lines = { string.format("Playing %q, %d stops.", reply.title, reply.stops) }
  if reply.diff then
    table.insert(lines, string.format("A tour of the diff %s..%s.", reply.diff.left:sub(1, 12),
      reply.diff.right:sub(1, 12)))
  end
  if reply.from_git and #reply.from_git > 0 then
    table.insert(lines, string.format("Changed since, so shown as commit %s has them: %s.",
      reply.commit:sub(1, 12), table.concat(reply.from_git, ", ")))
  end
  if not reply.complete then
    table.insert(lines, "It was saved before Claude finished writing it, so it may end abruptly.")
  end
  vim.list_extend(lines, reply.warnings or {})
  if not reply.nvim then
    table.insert(lines, "The narrator found no Neovim to highlight in.")
  end
  local level = vim.log.levels.INFO
  if (reply.players or 0) == 0 then
    table.insert(lines, "No player is listening: open the address `./dev narrator-url` prints on the host. Playback starts when it connects.")
    level = vim.log.levels.WARN
  end
  vim.notify(table.concat(lines, "\n"), level)
end

-- `:WalkthroughReplayOffline [file]`: a saved tour with no Claude at all. The
-- narrator plays a tour by itself in any case (Claude's part in a replay is
-- only to start it and to be there for questions), so this asks it directly,
-- through `narrator replay`, and names this Neovim as the one to highlight
-- in, rather than whichever the narrator would find for the project. Nobody
-- is there for questions, so Stop only holds the tour until Continue.
function M.replay_offline(opts)
  if vim.fn.executable("narrator") == 0 then
    vim.notify("WalkthroughReplayOffline: the narrator is not installed here (./dev reconfigure --with-narrator)",
      vim.log.levels.ERROR)
    return
  end
  local file, data = tour_arg(opts, "WalkthroughReplayOffline")
  if not file then return end
  prepare_replay(data, nil, function()
    local server = vim.v.servername
    if server == "" then server = vim.fn.serverstart() end
    vim.system({ "narrator", "replay", file, "--nvim", server }, { text = true }, function(r)
      vim.schedule(function() report_replay(r) end)
    end)
  end)
end

function M.setup()
  -- A stop that arrived while the Diffview tab was not on screen (show_in_diff)
  -- is shown on returning to it. Scheduled, so that Diffview's own TabEnter
  -- handling has run first.
  vim.api.nvim_create_autocmd("TabEnter", {
    group = vim.api.nvim_create_augroup("walkthrough", { clear = true }),
    callback = function()
      if not (pending and diff and diff.tab == vim.api.nvim_get_current_tabpage()) then return end
      vim.schedule(function()
        local p = pending
        if p and diff and diff.tab == vim.api.nvim_get_current_tabpage() then
          pcall(M.show, unpack(p, 1, 5))
        end
      end)
    end,
  })
  vim.api.nvim_create_user_command("Walkthrough", M.command, {
    nargs = "*",
    range = true,
    bang = true,
    desc = "Narrated walkthrough by Claude Code (of a topic, a range, or this file; ! for a deep tour of a diff)",
  })
  vim.api.nvim_create_user_command("WalkthroughReplay", M.replay, {
    nargs = "?",
    complete = function(lead)
      return vim.tbl_filter(function(f) return f:find(lead, 1, true) == 1 end, saved_tours())
    end,
    desc = "Replay a narrated walkthrough saved under .tours/",
  })
  vim.api.nvim_create_user_command("WalkthroughReplayOffline", M.replay_offline, {
    nargs = "?",
    complete = function(lead)
      return vim.tbl_filter(function(f) return f:find(lead, 1, true) == 1 end, saved_tours())
    end,
    desc = "Play a narrated walkthrough saved under .tours/, with no Claude",
  })
  local actions = { "prev", "next", "stop", "continue" }
  vim.api.nvim_create_user_command("WalkthroughControl", function(opts)
    if not vim.tbl_contains(actions, opts.args) then
      vim.notify("WalkthroughControl: one of " .. table.concat(actions, ", "), vim.log.levels.ERROR)
      return
    end
    M.control(opts.args)
  end, {
    nargs = 1,
    complete = function(lead)
      return vim.tbl_filter(function(a) return a:find(lead, 1, true) == 1 end, actions)
    end,
    desc = "Press a narrator button: prev, next, stop or continue",
  })
  vim.api.nvim_create_user_command("WalkthroughClear", function() M.clear() end,
    { desc = "Remove the walkthrough highlight and subtitle" })
end

return M
