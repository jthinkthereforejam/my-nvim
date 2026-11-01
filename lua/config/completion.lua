local M = {}
function M.setup()
  local ai = require('config.ai_completion')
  require('blink.cmp').setup({
    keymap = {
      preset = 'default',
      ['<Tab>'] = {
        function(cmp)
          -- Without a usable AI configuration, retain blink's original Tab.
          if not ai.status().enabled then return false end
          if cmp.is_menu_visible() then return cmp.select_and_accept() end
          return ai.accept()
        end,
        'snippet_forward', 'fallback',
      },
      ['<C-l>'] = {
        function()
          if not ai.status().enabled then return false end
          return ai.accept()
        end,
        'fallback',
      },
      ['<Esc>'] = {
        function() ai.dismiss(); return false end,
        'fallback',
      },
    },
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
