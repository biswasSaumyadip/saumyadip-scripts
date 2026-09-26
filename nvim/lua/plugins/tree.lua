-- managed by setup.ps1
return {
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    cmd = { "NvimTreeToggle", "NvimTreeFocus", "NvimTreeFindFileToggle" },
    keys = {
      { "<leader>e", "<cmd>NvimTreeToggle<CR>", desc = "File tree" },
      { "<leader>o", "<cmd>NvimTreeFindFileToggle<CR>", desc = "Tree reveal file" },
    },
    opts = {
      hijack_netrw = true,
      sync_root_with_cwd = true,
      view = { width = 34, side = "left" },
      renderer = {
        group_empty = true,
        highlight_git = true,
        icons = { show = { git = true, folder_arrow = true } },
      },
      filters = { dotfiles = false },
      git = { enable = true, ignore = false },
      actions = { open_file = { quit_on_open = false } },
    },
  },
}
