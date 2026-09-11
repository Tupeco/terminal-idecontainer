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

  -- Pinned to master: the main branch rewrite drops the classic setup API and
  -- :TSUpdateSync, which this config and the image build step rely on.
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "master",
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter.configs").setup({
        ensure_installed = {
          "python", "rust", "lua", "toml", "json", "yaml",
          "markdown", "markdown_inline", "bash", "regex", "vim", "vimdoc",
        },
        highlight = { enable = true },
        indent = { enable = true },
        incremental_selection = { enable = true },
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
      local hl_group = vim.api.nvim_create_augroup("lsp_doc_hl_" .. bufnr, { clear = true })
      vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
        group = hl_group,
        buffer = bufnr,
        callback = function() vim.lsp.buf.document_highlight() end,
      })
      vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = hl_group,
        buffer = bufnr,
        callback = function() vim.lsp.buf.clear_references() end,
      })
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
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR>")
vim.keymap.set("n", "<leader>w", "<cmd>write<CR>", { desc = "Write" })
vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", { desc = "Exit terminal mode" })
