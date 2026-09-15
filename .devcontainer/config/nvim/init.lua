-- Neovim config for a polyglot Python + Rust container.
-- Targets Neovim 0.11+ and uses the native vim.lsp.config/enable API.

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------
local o = vim.opt
o.number = true
o.relativenumber = true
o.signcolumn = "yes"
o.expandtab = true
o.shiftwidth = 4
o.tabstop = 4
o.smartindent = true
o.wrap = false
o.ignorecase = true
o.smartcase = true
o.undofile = true
o.updatetime = 250
-- Nvim's own default. This was 400, a value which-key-style configs often
-- suggest, but it is too tight for any mapping whose first key is also a
-- built-in prefix. Pause longer than this between `<C-w>` and `<C-f>` and the
-- mapping is abandoned mid-sequence, leaving you with built-in CTRL-W CTRL-F
-- ("edit the file name under the cursor") instead of diffview's. See TIPS.md.
o.timeoutlen = 1000
o.splitright = true
o.splitbelow = true
o.scrolloff = 8
o.termguicolors = true
o.mouse = "a"
o.completeopt = "menu,menuone,noselect"

-- OSC 52 clipboard. Neovim autodetects this over SSH but not reliably through
-- `docker exec`, so force it. Copying works in any OSC 52 capable terminal;
-- pasting generally does not, so use your terminal's own paste (Cmd-V).
local osc52 = require("vim.ui.clipboard.osc52")
vim.g.clipboard = {
  name = "OSC 52",
  copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
  paste = { ["+"] = osc52.paste("+"), ["*"] = osc52.paste("*") },
}

-- ---------------------------------------------------------------------------
-- Make messages visible
--
-- Nvim does report things like "No locations found" (runtime/lua/vim/lsp/buf.lua)
-- and "method ... is not supported by any server" — but as unhighlighted text in
-- the message line, which is trivially missed. Routing vim.notify through
-- nvim_echo colours it by level and still records it in :messages. Deliberately
-- level-based rather than matching message text, so an nvim upgrade that rewords
-- a message cannot silently switch this off.
-- ---------------------------------------------------------------------------
do
  local orig_notify = vim.notify
  local hl_for = {
    [vim.log.levels.INFO] = "MoreMsg",
    [vim.log.levels.WARN] = "WarningMsg",
    [vim.log.levels.ERROR] = "ErrorMsg",
  }
  vim.notify = function(msg, level, opts)
    level = level or vim.log.levels.INFO
    local hl = hl_for[level]
    if hl and type(msg) == "string" then
      vim.api.nvim_echo({ { msg, hl } }, true, {})
      return
    end
    return orig_notify(msg, level, opts)
  end
end

-- ---------------------------------------------------------------------------
-- Help in a floating window
--
-- Checks buftype rather than filetype: `:help` sets buftype=help itself, while
-- filetype depends on detection being enabled. The `relative ~= ""` guard stops
-- it re-floating a window that is already floating.
-- ---------------------------------------------------------------------------
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = vim.api.nvim_create_augroup("float_help", { clear = true }),
  callback = function(ev)
    if vim.bo[ev.buf].buftype ~= "help" then return end
    local win = vim.fn.bufwinid(ev.buf)
    if win == -1 or vim.api.nvim_win_get_config(win).relative ~= "" then return end
    local w = math.min(120, math.floor(vim.o.columns * 0.85))
    local h = math.floor(vim.o.lines * 0.85)
    vim.api.nvim_win_set_config(win, {
      relative = "editor",
      width = w,
      height = h,
      row = math.floor((vim.o.lines - h) / 2),
      col = math.floor((vim.o.columns - w) / 2),
      border = "rounded",
      title = " help ",
      title_pos = "center",
    })
  end,
})

-- ---------------------------------------------------------------------------
-- Pick up files changed outside nvim
--
-- 'autoread' is on by default, but Nvim never polls — it only compares
-- timestamps at certain moments. That is fine until something else is editing
-- your files: Claude Code in another pane, a rebase, a formatter. These are the
-- moments where a check is cheap. CursorHold fires after 'updatetime' (250ms)
-- of inactivity, so a file changed while you sit in it comes back almost at
-- once.
--
-- Worth knowing what this does *not* do: a buffer with unsaved changes is never
-- silently replaced. That case raises W12 and leaves the decision to you.
--
-- It also matters to the language server. Nvim does not enable
-- `workspace/didChangeWatchedFiles` on Linux, so until the buffer reloads the
-- server still holds our stale copy and can report diagnostics against lines
-- that no longer exist. The reload sends `didChange` and resyncs it.
-- ---------------------------------------------------------------------------
local external_changes = vim.api.nvim_create_augroup("external_changes", { clear = true })

vim.api.nvim_create_autocmd(
  { "FocusGained", "BufEnter", "CursorHold", "CursorHoldI", "TermClose" },
  {
    group = external_changes,
    callback = function()
      -- `:checktime` is rejected while the command line is open, and can knock
      -- you out of terminal mode. Skip both rather than let it error.
      if vim.fn.mode():match("^c") or vim.bo.buftype == "terminal" then return end
      pcall(vim.cmd, "checktime")
    end,
  }
)

-- Announce it. A buffer silently changing underneath you is worse than the
-- interruption, especially when you are about to wonder why your edit vanished.
--
-- FileChangedShellPost, not FileChangedShell: defining the latter *replaces*
-- Nvim's own handling of the change rather than adding to it.
vim.api.nvim_create_autocmd("FileChangedShellPost", {
  group = external_changes,
  callback = function(ev)
    local name = ev.file or vim.api.nvim_buf_get_name(0)
    vim.notify("Reloaded from disk: " .. vim.fn.fnamemodify(name, ":~:."), vim.log.levels.INFO)
  end,
})

-- ---------------------------------------------------------------------------
-- Quick reference: `:Tips`, plus a greeting on an otherwise empty start.
-- Rendered from the bind-mounted TIPS.md; see lua/devtips.lua.
-- ---------------------------------------------------------------------------
require("devtips").setup()

-- ---------------------------------------------------------------------------
-- lazy.nvim bootstrap
-- ---------------------------------------------------------------------------
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none", "--branch=stable",
    "https://github.com/folke/lazy.nvim.git", lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  { "folke/tokyonight.nvim", priority = 1000, config = function()
      vim.cmd.colorscheme("tokyonight-night")
    end },

  -- The `main` branch, not `master`.
  --
  -- master is pinned to Neovim 0.10/0.11 and says so in its own README: "Neovim
  -- 0.12 is not supported". Running it on 0.12 breaks markdown in particular,
  -- because master's queries/markdown/injections.scm uses a custom directive,
  -- `#set-lang-from-info-string!`, that only its own Lua registers. Plugin
  -- runtimepath entries beat $VIMRUNTIME, so that query shadows the one Nvim
  -- ships, and any markdown buffer containing a fenced code block throws
  -- "attempt to call method 'range' (a nil value)" during injection parsing.
  -- LSP hover floats are markdown with fenced code blocks, so this is not
  -- limited to reading documentation.
  --
  -- main drops the old `configs.setup()` API entirely: it installs parsers and
  -- queries, and everything else is core Neovim. Highlighting is
  -- `vim.treesitter.start()`, folding is `vim.treesitter.foldexpr()`, injections
  -- need no setup at all. `incremental_selection` is gone with no replacement;
  -- Nvim's own `v_an`/`v_in` text objects cover much of it.
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    build = ":TSUpdate",
    lazy = false,
    config = function()
      local langs = {
        "python", "rust", "lua", "toml", "json", "yaml",
        "markdown", "markdown_inline", "bash", "regex", "vim", "vimdoc",
      }

      require("nvim-treesitter").setup()
      -- Asynchronous, and a no-op when the parsers are already baked into the
      -- image. The Dockerfile does the synchronous version at build time.
      require("nvim-treesitter").install(langs)

      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("treesitter_start", { clear = true }),
        callback = function(ev)
          local lang = vim.treesitter.language.get_lang(vim.bo[ev.buf].filetype)
          if not lang then return end
          -- Only start where a parser actually exists, so opening a file type we
          -- never installed fails quietly instead of erroring on every buffer.
          if not pcall(vim.treesitter.start, ev.buf, lang) then return end
          -- Upstream still calls treesitter indentation experimental; it is the
          -- one piece here that is not core Neovim. Deliberately no foldexpr:
          -- treesitter folding would open every file collapsed unless foldlevel
          -- is also raised, and the previous config had no folding at all.
          vim.bo[ev.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
        end,
      })
    end,
  },

  -- Provides the lsp/*.lua definitions consumed by vim.lsp.enable below.
  { "neovim/nvim-lspconfig" },

  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "hrsh7th/cmp-buffer",
      "hrsh7th/cmp-path",
      "L3MON4D3/LuaSnip",
      "saadparwaiz1/cmp_luasnip",
    },
    config = function()
      local cmp = require("cmp")
      local luasnip = require("luasnip")
      cmp.setup({
        snippet = { expand = function(args) luasnip.lsp_expand(args.body) end },
        mapping = cmp.mapping.preset.insert({
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<C-e>"] = cmp.mapping.abort(),
          ["<CR>"] = cmp.mapping.confirm({ select = false }),
          ["<Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then cmp.select_next_item()
            elseif luasnip.expand_or_jumpable() then luasnip.expand_or_jump()
            else fallback() end
          end, { "i", "s" }),
          ["<S-Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then cmp.select_prev_item()
            elseif luasnip.jumpable(-1) then luasnip.jump(-1)
            else fallback() end
          end, { "i", "s" }),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp" },
          { name = "luasnip" },
        }, {
          { name = "buffer" },
          { name = "path" },
        }),
      })
    end,
  },

  -- Debugging. This is the main reason to keep Neovim around alongside Helix.
  {
    "mfussenegger/nvim-dap",
    dependencies = {
      "rcarriga/nvim-dap-ui",
      "nvim-neotest/nvim-nio",
      "theHamsta/nvim-dap-virtual-text",
      "mfussenegger/nvim-dap-python",
    },
    config = function()
      local dap, dapui = require("dap"), require("dapui")
      dapui.setup()
      require("nvim-dap-virtual-text").setup({})

      -- Python: debugpy lives in its own env so it is always present. If a
      -- project needs its own dependencies visible to the debugger, run
      -- `uv pip install debugpy` in that venv and swap the path here.
      require("dap-python").setup("/opt/debugpy/bin/python")

      -- Rust via lldb-dap.
      dap.adapters.lldb = {
        type = "executable",
        command = "lldb-dap",
        name = "lldb",
      }
      dap.configurations.rust = {
        {
          name = "Launch binary",
          type = "lldb",
          request = "launch",
          program = function()
            return vim.fn.input("Path to executable: ", vim.fn.getcwd() .. "/target/debug/", "file")
          end,
          cwd = "${workspaceFolder}",
          stopOnEntry = false,
          args = {},
        },
      }

      dap.listeners.before.attach.dapui_config = function() dapui.open() end
      dap.listeners.before.launch.dapui_config = function() dapui.open() end
      dap.listeners.before.event_terminated.dapui_config = function() dapui.close() end
      dap.listeners.before.event_exited.dapui_config = function() dapui.close() end

      vim.keymap.set("n", "<F5>", dap.continue, { desc = "DAP continue" })
      vim.keymap.set("n", "<F10>", dap.step_over, { desc = "DAP step over" })
      vim.keymap.set("n", "<F11>", dap.step_into, { desc = "DAP step into" })
      vim.keymap.set("n", "<F12>", dap.step_out, { desc = "DAP step out" })
      vim.keymap.set("n", "<leader>db", dap.toggle_breakpoint, { desc = "Toggle breakpoint" })
      vim.keymap.set("n", "<leader>dB", function()
        dap.set_breakpoint(vim.fn.input("Breakpoint condition: "))
      end, { desc = "Conditional breakpoint" })
      vim.keymap.set("n", "<leader>du", dapui.toggle, { desc = "Toggle DAP UI" })
    end,
  },

  {
    "ibhagwan/fzf-lua",
    config = function()
      local fzf = require("fzf-lua")
      fzf.setup({ "default" })
      vim.keymap.set("n", "<leader>ff", fzf.files, { desc = "Find files" })
      vim.keymap.set("n", "<leader>fg", fzf.live_grep, { desc = "Live grep" })
      vim.keymap.set("n", "<leader>fb", fzf.buffers, { desc = "Buffers" })
      vim.keymap.set("n", "<leader>fs", fzf.lsp_document_symbols, { desc = "Document symbols" })
      vim.keymap.set("n", "<leader>fS", fzf.lsp_live_workspace_symbols, { desc = "Workspace symbols" })
      vim.keymap.set("n", "<leader>fd", fzf.diagnostics_workspace, { desc = "Diagnostics" })
      -- The "what was that key again" picker: every mapping, with its
      -- description, searchable. This is the closest thing here to diffview's
      -- g? help panel, except it covers the whole editor.
      vim.keymap.set("n", "<leader>fk", fzf.keymaps, { desc = "Keymaps" })
      vim.keymap.set("n", "<leader>fj", fzf.jumps, { desc = "Jumplist" })
      vim.keymap.set("n", "<leader>fh", fzf.helptags, { desc = "Help tags" })
    end,
  },

  {
    "lewis6991/gitsigns.nvim",
    config = function() require("gitsigns").setup() end,
  },

  -- Whole-repo diff between any two revisions: a file panel down the left,
  -- side-by-side diff on the right, <tab>/<s-tab> to walk the changed files.
  -- This is the closest thing here to PyCharm's "Compare with Branch".
  --
  -- Deliberately the fork, not sindrets/diffview.nvim. The original is the one
  -- every guide links to, but it has had no commits since August 2024 while
  -- issues keep being filed against it; this fork is where the fixes land.
  {
    "dlyongemallo/diffview-plus.nvim",
    version = "*",
    -- The Lua module is still `diffview`, so lazy.nvim cannot infer it from
    -- the repository name.
    main = "diffview",
    cmd = {
      "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory",
      "DiffviewToggleFiles", "DiffviewFocusFiles", "DiffviewDiffDirs",
    },
    keys = {
      { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Diff working tree" },
      -- Left deliberately unterminated: type the revision and hit enter, e.g.
      -- `main..feature`, `v1.0..v2.0`, or `origin/main...HEAD` for PR-style.
      { "<leader>gc", ":DiffviewOpen ", desc = "Compare with rev (type one)" },
      { "<leader>gh", "<cmd>DiffviewFileHistory %<cr>", desc = "History: this file" },
      { "<leader>gH", "<cmd>DiffviewFileHistory<cr>", desc = "History: whole repo" },
      { "<leader>gq", "<cmd>DiffviewClose<cr>", desc = "Close diffview" },
    },
    opts = {
      -- Better highlighting of what actually changed within a changed line.
      enhanced_diff_hl = true,
      view = {
        -- Two panes, old on the left and new on the right, which is the layout
        -- the PyCharm habit expects.
        default = { layout = "diff2_horizontal" },
        merge_tool = { layout = "diff3_horizontal" },
      },
    },
  },

  {
    "stevearc/conform.nvim",
    config = function()
      require("conform").setup({
        formatters_by_ft = {
          python = { "ruff_format", "ruff_organize_imports" },
          rust = { "rustfmt" },
          lua = { "stylua" },
        },
        format_on_save = { timeout_ms = 2000, lsp_format = "fallback" },
      })
    end,
  },

  -- Project tree in a side split: the closest thing here to PyCharm's Project
  -- pane. Vetted before adding, given how the diffview situation turned out:
  -- v3.42.0 shipped 2026-09-01, commits are landing weekly, and v3.x is the
  -- branch upstream tells you to pin.
  --
  -- `lazy = false` is required rather than cosmetic: neo-tree has to be loaded
  -- at startup to take over directory arguments, which is what makes `nvim .`
  -- open the tree instead of netrw.
  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      -- Optional. Supplies per-filetype file icons; the folder glyphs come from
      -- neo-tree's own defaults either way, so both want a Nerd Font in the
      -- terminal. If yours has none, drop this line and set plain-text icons
      -- via `default_component_configs.icon`.
      "nvim-tree/nvim-web-devicons",
    },
    lazy = false,
    keys = {
      { "<leader>tt", "<cmd>Neotree toggle<cr>",                    desc = "Tree: toggle" },
      { "<leader>tf", "<cmd>Neotree reveal<cr>",                    desc = "Tree: reveal current file" },
      { "<leader>tg", "<cmd>Neotree float git_status<cr>",          desc = "Tree: git status" },
      { "<leader>tb", "<cmd>Neotree toggle show buffers right<cr>", desc = "Tree: buffers" },
    },
    opts = {
      -- Never leave a lone tree window holding the tab open.
      close_if_last_window = true,
      filesystem = {
        -- PyCharm's "Select Opened File", but automatic.
        follow_current_file = { enabled = true },
        -- Take over `nvim <dir>`. "open_default" puts the tree in the sidebar
        -- and leaves an empty editor window beside it; "open_current" would
        -- fill the whole window instead, which is just netrw again.
        hijack_netrw_behavior = "open_default",
        use_libuv_file_watcher = true,
        filtered_items = {
          hide_dotfiles = false,
          hide_gitignored = true,
        },
      },
      window = { width = 32 },
    },
  },

  -- PyCharm's error stripe: the marker bar down the right-hand edge showing
  -- where the problems are in the whole file, not just the visible part.
  --
  -- satellite rather than nvim-scrollview because it has a gitsigns handler, so
  -- changed hunks appear on the stripe alongside the diagnostics. Scrollview
  -- covers more sign types overall but has no notion of git hunks: its
  -- `latestchange` and `changelist` groups are Vim's own change marks.
  --
  -- Occurrences of the symbol under the cursor are not built into any scrollbar
  -- plugin, so the handler below adds them. It reads the extmarks Nvim's own LSP
  -- reference highlighter already writes, so it costs no extra LSP requests.
  {
    "lewis6991/satellite.nvim",
    event = "VeryLazy",
    config = function()
      require("satellite").setup({
        -- Decorate only the focused window; a stripe in every split is noise.
        current_only = true,
        excluded_filetypes = { "neo-tree", "DiffviewFiles", "DiffviewFileHistory", "help" },
        winblend = 30,
        handlers = {
          cursor = { enable = true },
          search = { enable = true },
          diagnostic = { enable = true },
          gitsigns = { enable = true },
          marks = { enable = true, show_builtins = false },
          quickfix = { enable = true },
        },
      })

      -- ---------------------------------------------------------------------
      -- Custom handler: occurrences of the symbol under the cursor
      --
      -- `vim.lsp.buf.document_highlight()` (wired to CursorHold in the LspAttach
      -- block above) highlights occurrences in the visible text by writing
      -- extmarks into a namespace Nvim names `nvim.lsp.references`.
      -- nvim_create_namespace is idempotent by name, so this handler reads those
      -- same extmarks back and turns them into scrollbar marks. No second
      -- request, and the stripe cannot drift out of sync with the highlighting
      -- because both come from the same marks.
      -- ---------------------------------------------------------------------
      local util = require("satellite.util")
      local ref_ns = vim.api.nvim_create_namespace("nvim.lsp.references")

      local handler = { name = "lsp_references" }

      handler.setup = function(config0, update)
        handler.config = vim.tbl_deep_extend("force", {
          enable = true,
          -- `overlap = true` draws the mark as overlay virtual text *on* the
          -- scrollbar, which is what every built-in handler does. With
          -- `overlap = false` satellite uses `sign_text` instead, which opens a
          -- separate sign column beside the bar — the marks then sit next to the
          -- diagnostics rather than sharing the same column.
          overlap = true,
          -- Below the diagnostic handler's 50, deliberately. Marks at the same
          -- scrollbar row are resolved by extmark priority, and an error must
          -- never be hidden behind "this symbol also appears here".
          priority = 40,
        }, config0 or {})

        vim.api.nvim_set_hl(0, "SatelliteLspReference", {
          default = true,
          link = "LspReferenceText",
        })

        local group = vim.api.nvim_create_augroup("satellite_lsp_references", { clear = true })

        -- Update exactly when the highlight reply lands, rather than guessing
        -- with a timer. `document_highlight()` is asynchronous, so a fixed delay
        -- was either too early (no marks yet) or needlessly laggy.
        vim.api.nvim_create_autocmd("LspRequest", {
          group = group,
          callback = function(ev)
            local request = ev.data and ev.data.request
            if
              request
              and request.type == "complete"
              and request.method == "textDocument/documentHighlight"
            then
              update()
            end
          end,
        })

        -- Nothing clears the highlights on cursor movement any more — they are
        -- dismissed explicitly — so there is no CursorMoved trigger here. The
        -- clear path calls :SatelliteRefresh itself.
      end

      handler.update = function(bufnr, winid)
        local marks, seen = {}, {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ref_ns, 0, -1, {})) do
          -- Extmark rows and row_to_barpos are both 0-indexed, so no adjustment.
          local pos = util.row_to_barpos(winid, m[2])
          if not seen[pos] then
            seen[pos] = true
            marks[#marks + 1] = {
              pos = pos,
              highlight = "SatelliteLspReference",
              symbol = "▐",
            }
          end
        end
        return marks
      end

      require("satellite.handlers").register(handler)
    end,
  },

  { "nvim-lualine/lualine.nvim", config = function()
      require("lualine").setup({ options = { theme = "tokyonight" } })
    end },

  { "windwp/nvim-autopairs", event = "InsertEnter", opts = {} },
}, {
  install = { colorscheme = { "tokyonight-night", "habamax" } },
  checker = { enabled = false },
})

-- ---------------------------------------------------------------------------
-- LSP
-- ---------------------------------------------------------------------------
local caps = vim.tbl_deep_extend(
  "force",
  vim.lsp.protocol.make_client_capabilities(),
  require("cmp_nvim_lsp").default_capabilities()
)

vim.lsp.config("*", { capabilities = caps })

vim.lsp.config("basedpyright", {
  settings = {
    basedpyright = {
      analysis = {
        typeCheckingMode = "standard",
        autoImportCompletions = true,
        diagnosticMode = "openFilesOnly",
      },
    },
  },
})

vim.lsp.config("ruff", {})

vim.lsp.config("rust_analyzer", {
  settings = {
    ["rust-analyzer"] = {
      cargo = { features = "all" },
      check = { command = "clippy" },
      inlayHints = {
        bindingModeHints = { enable = true },
        closureReturnTypeHints = { enable = "with_block" },
      },
    },
  },
})

vim.lsp.enable({ "basedpyright", "ruff", "rust_analyzer" })

vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args)
    local bufnr = args.buf
    local function map(keys, fn, desc)
      vim.keymap.set("n", keys, fn, { buffer = bufnr, desc = "LSP: " .. desc })
    end
    map("gd", vim.lsp.buf.definition, "Go to definition")
    map("gD", vim.lsp.buf.declaration, "Go to declaration")
    map("gr", vim.lsp.buf.references, "References")
    map("gi", vim.lsp.buf.implementation, "Implementation")
    map("K", vim.lsp.buf.hover, "Hover")
    map("<leader>rn", vim.lsp.buf.rename, "Rename")
    map("<leader>ca", vim.lsp.buf.code_action, "Code action")
    map("[d", function() vim.diagnostic.jump({ count = -1 }) end, "Previous diagnostic")
    map("]d", function() vim.diagnostic.jump({ count = 1 }) end, "Next diagnostic")

    -- PyCharm's Call Hierarchy. Nvim 0.11+ already binds the rest of the LSP
    -- verbs globally (grn rename, gra code action, grr references, gri
    -- implementation, grt type definition, gO document symbols, insert-mode
    -- CTRL-S signature help), but not these two.
    map("<leader>ci", vim.lsp.buf.incoming_calls, "Incoming calls")
    map("<leader>co", vim.lsp.buf.outgoing_calls, "Outgoing calls")

    -- Ctrl-click to jump to a definition. The built-in <C-LeftMouse> is
    -- jump-to-tag, which does nothing useful without a tags file. The leading
    -- <LeftMouse> is required: it is what moves the cursor to what you clicked,
    -- before the handler reads the position under it.
    vim.keymap.set(
      "n",
      "<C-LeftMouse>",
      "<LeftMouse><cmd>lua vim.lsp.buf.definition()<cr>",
      { buffer = bufnr, desc = "LSP: Go to definition (ctrl-click)" }
    )

    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client and client:supports_method("textDocument/inlayHint") then
      vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
    end

    -- Highlight the other occurrences of whatever is under the cursor. This is
    -- the semantic version, not a word match: the server decides what counts as
    -- the same symbol, so a local `x` does not light up an unrelated `x`. Fires
    -- after `updatetime` (250ms). The LspReference* highlight groups it uses are
    -- defined by Nvim itself, so this needs nothing from the colorscheme.
    if client and client:supports_method("textDocument/documentHighlight") then
      -- Deliberately a keypress, not an autocommand.
      --
      -- Driving this from the cursor means scrolling re-targets it, because
      -- Vim's cursor cannot leave the viewport and gets dragged along. Every
      -- automatic fix for that is a guess about intent. Asking for the
      -- highlight makes it behave like `hlsearch`: it appears when you say so
      -- and stays until you dismiss it, including while you scroll around
      -- looking at the very occurrences you asked for.
      --
      -- `<leader><CR>` rather than bare `<CR>`: the quickfix window's `<CR>`
      -- (jump to entry) is built into Nvim rather than a buffer-local mapping,
      -- so a global `<CR>` map shadows it — and `grr`/`gri` put their results
      -- in the quickfix list.
      local ref_ns = vim.api.nvim_create_namespace("nvim.lsp.references")
      map("<leader><CR>", function()
        local shown = #vim.api.nvim_buf_get_extmarks(bufnr, ref_ns, 0, -1, {}) > 0
        if shown then
          vim.lsp.buf.clear_references()
          pcall(vim.cmd, "silent! SatelliteRefresh")
        else
          -- Asynchronous; the marker bar updates itself when the reply lands.
          vim.lsp.buf.document_highlight()
        end
      end, "Toggle occurrence highlight")
    end
  end,
})

vim.diagnostic.config({
  virtual_text = { spacing = 2, prefix = "●" },
  severity_sort = true,
  float = { border = "rounded", source = true },
})

-- ---------------------------------------------------------------------------
-- Misc keymaps
-- ---------------------------------------------------------------------------
-- One key to dismiss every "highlight" in the buffer: search matches and the
-- occurrence highlight from <leader><CR>.
vim.keymap.set("n", "<Esc>", function()
  vim.cmd("nohlsearch")
  pcall(vim.lsp.buf.clear_references)
  pcall(vim.cmd, "silent! SatelliteRefresh")
end, { desc = "Clear search and occurrence highlights" })
vim.keymap.set("n", "<leader>w", "<cmd>write<CR>", { desc = "Write" })
vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", { desc = "Exit terminal mode" })
