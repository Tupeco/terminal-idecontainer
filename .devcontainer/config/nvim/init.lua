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
o.timeoutlen = 400
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
    end,
  },

  {
    "lewis6991/gitsigns.nvim",
    config = function() require("gitsigns").setup() end,
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

    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client and client:supports_method("textDocument/inlayHint") then
      vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
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
