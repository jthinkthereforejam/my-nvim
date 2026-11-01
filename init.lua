-- Based on kickstart.nvim (MIT), upstream 8e35dbedb7966e3a95e1f26f9fc1179ab6c68db4.
local version = vim.version()
if version.major ~= 0 or version.minor ~= 12 or version.patch ~= 6 then
  error('This configuration requires Neovim 0.12.6; found ' .. tostring(version))
end
local root = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))
vim.g.my_nvim_root = root
vim.opt.runtimepath:prepend(root)
vim.loader.enable()
local machine = require('config.machine').load()
require('config.machine').apply(machine)
require('config.project').prepare(machine)
require('config.options').setup()
require('config.cmdline').setup(machine)
require('config.lsp').prepare(machine)
vim.g.fff = { lazy_sync = true }
require('config.plugins').setup()
vim.g.everforest_background = 'medium'
vim.g.everforest_better_performance = 1
vim.o.background = 'dark'
vim.cmd.colorscheme('everforest')
require('config.completion').setup()
require('config.whichkey').setup(machine)
require('config.treesitter').setup(machine)
require('config.lsp').setup(machine)
require('config.search').setup(machine)
require('config.terminal').setup(machine)
require('config.project').setup(machine)
require('config.welcome').setup(machine)
vim.g.my_nvim_ready = true
