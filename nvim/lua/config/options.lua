-- managed by setup.ps1
local o = vim.opt

o.number = true
o.relativenumber = true
o.signcolumn = "yes"
o.cursorline = true
o.termguicolors = true
o.winborder = "rounded"

o.tabstop = 4
o.shiftwidth = 4
o.softtabstop = 4
o.expandtab = true
o.smartindent = true

o.ignorecase = true
o.smartcase = true
o.hlsearch = true
o.incsearch = true

o.splitright = true
o.splitbelow = true
o.scrolloff = 6
o.sidescrolloff = 8
o.wrap = false

o.undofile = true
o.swapfile = false
o.backup = false
o.updatetime = 250
o.timeoutlen = 400

o.clipboard = "unnamedplus"
o.mouse = "a"
o.completeopt = { "menu", "menuone", "noselect" }
o.list = true
o.listchars = { tab = "» ", trail = "·", nbsp = "␣" }

vim.diagnostic.config({
  virtual_text = { spacing = 2, prefix = "●" },
  float = { border = "rounded", source = "if_many" },
  severity_sort = true,
})
