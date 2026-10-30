local M = {}
function M.setup()
  require('blink.cmp').setup({
    keymap = { preset = 'default' },
    -- A portable Lua matcher avoids a second native binary dependency.
    fuzzy = { implementation = 'lua' },
    sources = { default = { 'lsp', 'path', 'snippets', 'buffer' } },
    completion = {
      documentation = { auto_show = true, auto_show_delay_ms = 300 },
      menu = { draw = { columns = { { 'label', 'label_description', gap = 1 }, { 'kind' } } } },
    },
    signature = { enabled = true },
    cmdline = { enabled = false },
  })
end
return M
