-- Highlight every occurrence of the thing under the cursor.
--
-- Semantically when a language server can say what "the same symbol" means,
-- textually when it cannot. The textual path matters more than it sounds: a
-- server that has not resolved a name answers documentHighlight with nothing
-- at all -- no error, no empty list, just nil -- which is exactly the state you
-- are in while a dependency is missing, and exactly when you most want to see
-- where a name is used.
--
-- Deliberately a keypress rather than an autocommand: Vim's cursor cannot leave
-- the viewport, so anything driven by cursor position re-targets itself while
-- you scroll to look at the occurrences you just asked for.

local M = {}

local ref_ns = vim.api.nvim_create_namespace("nvim.lsp.references")

--- The pattern we last put in the search register. Dismissing only clears a
--- highlight we created; a search you ran yourself is yours to keep.
local ours = nil

--- A whole-word, wholly-literal pattern for the word under the cursor, or nil
--- when there is no word there to match.
local function word_pattern()
  local word = vim.fn.expand("<cword>")
  if word == "" then return nil end
  local pat = [[\V\<]] .. vim.fn.escape(word, [[\/]]) .. [[\>]]
  -- `\<` and `\>` need keyword characters at the edges. Rather than guess at
  -- 'iskeyword', ask whether the pattern matches the word it was built from:
  -- on punctuation it does not, and there is nothing sensible to highlight.
  if vim.fn.match(word, pat) == -1 then return nil end
  return pat
end

--- Is the cursor inside one of the LSP occurrence highlights? Extmark ends are
--- exclusive, so querying at the cursor position alone would count the
--- character just past a lit word as being on it.
local function on_lsp_occurrence(bufnr)
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1] - 1, cur[2]
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr, ref_ns, { row, 0 }, { row, -1 }, { details = true, overlap = true })
  for _, m in ipairs(marks) do
    local srow, scol = m[2], m[3]
    local d = m[4] or {}
    local erow, ecol = d.end_row or srow, d.end_col or scol
    if (srow < row or (srow == row and scol <= col))
      and (erow > row or (erow == row and ecol > col)) then
      return true
    end
  end
  return false
end

--- Is the live search highlight one of ours, for the word under the cursor?
local function on_our_search()
  if vim.v.hlsearch ~= 1 or not ours then return false end
  if vim.fn.getreg("/") ~= ours then return false end
  return ours == word_pattern()
end

--- satellite.nvim's search handler reads `v:hlsearch` and the search register,
--- so the fallback shows up on the marker bar for free -- but it only polls
--- `v:hlsearch` for *changes*, and re-targeting from one word to another leaves
--- it at 1. Firing its documented User event keeps the bar in step.
local function tell_satellite(data)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "Search", data = data })
end

local function clear()
  vim.lsp.buf.clear_references()
  if ours and vim.fn.getreg("/") == ours then
    vim.cmd("nohlsearch")
    tell_satellite({ hlsearch = 0 })
  end
  ours = nil
  pcall(vim.cmd, "silent! SatelliteRefresh")
end

--- Highlight the word under the cursor the way `*` would, without moving.
local function search_fallback()
  local pat = word_pattern()
  if not pat then
    vim.notify("Nothing to highlight under the cursor", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg("/", pat)
  vim.fn.histadd("search", pat)   -- so `n`, `N` and `q/` behave as you expect
  vim.v.searchforward = 1
  vim.v.hlsearch = 1
  ours = pat
  tell_satellite({ pattern = pat })
end

--- On a lit occurrence this dismisses; anywhere else it re-targets.
function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  local dismiss = on_lsp_occurrence(bufnr) or on_our_search()
  -- Clear unconditionally: the documentHighlight handler only ever *adds*
  -- extmarks, so without this a re-target leaves the previous symbol lit
  -- alongside the new one.
  clear()
  if dismiss then return end

  local clients = vim.lsp.get_clients({
    bufnr = bufnr,
    method = "textDocument/documentHighlight",
  })
  if #clients == 0 then return search_fallback() end

  -- Our own handler rather than vim.lsp.buf.document_highlight(), so we can see
  -- that a reply was empty and fall back. Nvim runs response handlers before it
  -- fires LspRequest 'complete', so the marker bar still updates off the marks
  -- this writes.
  local pending, any = #clients, false
  for _, client in ipairs(clients) do
    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    client:request("textDocument/documentHighlight", params, function(err, result)
      if not err and result and #result > 0 then
        any = true
        vim.lsp.util.buf_highlight_references(bufnr, result, client.offset_encoding)
      end
      pending = pending - 1
      if pending == 0 and not any then search_fallback() end
    end, bufnr)
  end
end

--- Dismiss from anywhere, for <Esc>.
function M.clear()
  clear()
end

return M
