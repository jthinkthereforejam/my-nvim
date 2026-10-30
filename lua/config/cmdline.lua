-- Shell-style path completion stays native; blink.cmp is for Insert mode.
local M = {}

function M.setup(_machine)
  vim.opt.wildmenu = true
  vim.opt.wildoptions = { 'pum' }
  vim.opt.wildmode = 'longest:full,full'

  vim.keymap.set('c', '<Up>', function()
    return vim.fn.wildmenumode() == 1 and '<C-p>' or '<Up>'
  end, { expr = true, desc = 'Previous completion or command history' })
  vim.keymap.set('c', '<Down>', function()
    return vim.fn.wildmenumode() == 1 and '<C-n>' or '<Down>'
  end, { expr = true, desc = 'Next completion or command history' })
  vim.keymap.set('c', '<Tab>', function()
    local info = vim.fn.cmdcomplete_info()
    local selected = info.selected or -1
    if vim.fn.wildmenumode() == 1 and selected >= 0 then
      local match = (info.matches or {})[selected + 1] or ''
      -- C-y accepts without executing the Ex command; C-z starts the next level.
      return match:match('[/\\]$') and '<C-y><C-z>' or '<C-y>'
    end
    -- C-z is Neovim 0.12's mapping-safe native completion trigger.
    return '<C-z>'
  end, { expr = true, desc = 'Complete common prefix or accept selected path' })
end

return M
