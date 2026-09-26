-- managed by setup.ps1
return {
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    event = { "BufReadPost", "BufNewFile" },
    opts = {
      ensure_installed = {
        "lua",
        "vim",
        "vimdoc",
        "query",
        "java",
        "javascript",
        "typescript",
        "tsx",
        "python",
        "c",
        "cpp",
        "cmake",
        "json",
        "html",
        "css",
        "bash",
        "markdown",
        "markdown_inline",
        "yaml",
        "toml",
      },
      highlight = { enable = true },
      indent = { enable = true },
      incremental_selection = {
        enable = true,
        keymaps = {
          init_selection = "<CR>",
          node_incremental = "<CR>",
          node_decremental = "<BS>",
        },
      },
    },
    config = function(_, opts)
      require("nvim-treesitter.configs").setup(opts)
    end,
  },
}
