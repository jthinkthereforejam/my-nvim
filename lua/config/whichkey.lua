local M = {}

function M.setup(_machine)
  require('which-key').setup({
    preset = 'classic',
    delay = 200,
    win = { padding = { 0, 1 }, height = { min = 4, max = 12 } },
    layout = { width = { min = 18, max = 32 }, spacing = 2 },
    icons = { mappings = false, breadcrumb = '>', separator = '->', group = '+', ellipsis = '...' },
    -- Native key names such as <Esc> and <C-d>, without Nerd Font glyphs.
    replace = { key = { function(key) return key end } },
    sort = {
      function(item) return item.node.keys == 'gr' and -1 or 0 end,
      'local', 'order', 'group', 'alphanum', 'mod',
    },
    expand = 0,
    keys = { scroll_down = '<C-d>', scroll_up = '<C-u>' },
    triggers = { { '<auto>', mode = 'nxso' }, { 'g', mode = 'n' } },
    spec = {
      { 'gr', group = 'LSP' },
      { '<leader>g', group = 'Git' },
      { '<leader>s', group = 'Search' },
      { '<leader>p', group = 'Project' },
      { '<leader>t', group = 'Terminal / Toggle' },
    },
  })
end

return M
