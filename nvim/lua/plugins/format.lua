-- managed by setup.ps1
return {
  {
    "stevearc/conform.nvim",
    event = { "BufWritePre" },
    cmd = { "ConformInfo" },
    opts = {
      formatters_by_ft = {
        lua = { "stylua" },
        python = { "ruff_format", "ruff_organize_imports" },
        javascript = { "prettier" },
        javascriptreact = { "prettier" },
        typescript = { "prettier" },
        typescriptreact = { "prettier" },
        json = { "prettier" },
        html = { "prettier" },
        css = { "prettier" },
        markdown = { "prettier" },
        yaml = { "prettier" },
        c = { "clang_format" },
        cpp = { "clang_format" },
        java = { "google-java-format" },
      },
      format_on_save = {
        timeout_ms = 2000,
        lsp_fallback = true,
        lsp_format = "fallback",
      },
    },
  },
}
