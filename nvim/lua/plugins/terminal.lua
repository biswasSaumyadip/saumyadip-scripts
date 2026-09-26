-- managed by setup.ps1
return {
  {
    "akinsho/toggleterm.nvim",
    version = "*",
    cmd = { "ToggleTerm", "TermExec" },
    keys = {
      { "<leader>tt", "<cmd>ToggleTerm<CR>", desc = "Toggle terminal" },
    },
    opts = {
      open_mapping = [[<c-\>]],
      direction = "float",
      float_opts = { border = "rounded" },
      shade_terminals = true,
    },
  },
}
