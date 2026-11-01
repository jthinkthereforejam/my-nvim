-- Familiar kickstart defaults, with explicit display and formatting preferences.
local M = {}
function M.setup()
  vim.g.mapleader = ' '
  vim.g.maplocalleader = ' '
  vim.g.have_nerd_font = false
  vim.opt.number = true
  vim.opt.relativenumber = true
  vim.opt.cursorline = true
  vim.opt.signcolumn = 'yes'
  vim.opt.termguicolors = true
  vim.opt.mouse = 'a'
  vim.opt.breakindent = true
  vim.opt.undofile = true
  vim.opt.ignorecase = true
  vim.opt.smartcase = true
  vim.opt.updatetime = 250
  vim.opt.timeoutlen = 400
  vim.opt.splitright = true
  vim.opt.splitbelow = true
  vim.opt.scrolloff = 8
  vim.opt.inccommand = 'split'
  vim.opt.confirm = true
  vim.opt.winborder = 'rounded'
  -- Insert spaces; one indentation/Tab/Backspace step is four columns.
  vim.opt.expandtab = true
  vim.opt.shiftwidth = 4
  vim.opt.tabstop = 4
  vim.opt.softtabstop = 4
  vim.opt.completeopt = { 'menu', 'menuone', 'noselect' }
  vim.schedule(function() vim.opt.clipboard = 'unnamedplus' end)
  vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>', { desc = 'Clear search highlight', silent = true })
  -- Ctrl+J belongs to the terminal panel; Ctrl+W j still moves down.
  for _, direction in ipairs({ 'h', 'k', 'l' }) do
    vim.keymap.set('n', '<C-' .. direction .. '>', '<C-w>' .. direction, { desc = 'Focus adjacent window' })
  end
  vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Diagnostic list' })
  vim.diagnostic.config({
    severity_sort = true,
    update_in_insert = false,
    underline = true,
    virtual_text = true,
    virtual_lines = false,
    float = { border = 'rounded', source = 'if_many' },
  })
end
return M
