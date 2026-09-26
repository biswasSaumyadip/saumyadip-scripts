-- managed by setup.ps1
return {
  {
    "williamboman/mason.nvim",
    cmd = { "Mason", "MasonInstall" },
    opts = { ui = { border = "rounded" } },
  },
  {
    "williamboman/mason-lspconfig.nvim",
    dependencies = { "williamboman/mason.nvim" },
  },
  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    dependencies = { "williamboman/mason.nvim" },
    opts = {
      ensure_installed = {
        "lua-language-server",
        "typescript-language-server",
        "basedpyright",
        "ruff",
        "clangd",
        "jdtls",
        "json-lsp",
        "html-lsp",
        "css-lsp",
        "bash-language-server",
        "stylua",
        "prettier",
        "clang-format",
        "google-java-format",
      },
      run_on_start = true,
    },
  },
  {
    "neovim/nvim-lspconfig",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = {
      "williamboman/mason.nvim",
      "williamboman/mason-lspconfig.nvim",
      "hrsh7th/cmp-nvim-lsp",
    },
    config = function()
      require("mason").setup({ ui = { border = "rounded" } })

      local servers = {
        "lua_ls",
        "ts_ls",
        "basedpyright",
        "ruff",
        "clangd",
        "jsonls",
        "html",
        "cssls",
        "bashls",
      }

      pcall(function()
        require("mason-lspconfig").setup({
          ensure_installed = { "lua_ls", "ts_ls", "basedpyright", "clangd", "jdtls", "jsonls" },
        })
      end)

      local capabilities = vim.lsp.protocol.make_client_capabilities()
      pcall(function()
        capabilities = require("cmp_nvim_lsp").default_capabilities(capabilities)
      end)

      local on_attach = function(_, bufnr)
        local map = function(mode, lhs, rhs, desc)
          vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, silent = true, desc = desc })
        end
        map("n", "gd", vim.lsp.buf.definition, "Goto definition")
        map("n", "gr", vim.lsp.buf.references, "References")
        map("n", "K", vim.lsp.buf.hover, "Hover")
        map("n", "<leader>ca", vim.lsp.buf.code_action, "Code action")
        map("n", "<leader>rn", vim.lsp.buf.rename, "Rename")
      end

      local settings = {
        lua_ls = {
          settings = {
            Lua = {
              diagnostics = { globals = { "vim" } },
              workspace = { checkThirdParty = false },
              telemetry = { enable = false },
            },
          },
        },
        basedpyright = {
          settings = {
            basedpyright = {
              analysis = { typeCheckingMode = "standard" },
            },
          },
        },
        clangd = {
          cmd = { "clangd", "--background-index", "--clang-tidy" },
        },
      }

      local function setup_server(name)
        local opts = vim.tbl_deep_extend("force", {
          capabilities = capabilities,
          on_attach = on_attach,
        }, settings[name] or {})

        if vim.lsp.config and vim.lsp.enable then
          vim.lsp.config(name, opts)
          vim.lsp.enable(name)
          return
        end

        local ok, lspconfig = pcall(require, "lspconfig")
        if ok and lspconfig[name] then
          lspconfig[name].setup(opts)
        end
      end

      for _, name in ipairs(servers) do
        setup_server(name)
      end
    end,
  },
}
