-- nvim --headless -u ./init.lua -i NONE -l tests/whichkey_native.lua
assert(vim.g.my_nvim_ready, 'Load the my-nvim configuration for this integration test')
vim.o.columns, vim.o.lines = 120, 24
vim.keymap.set('n', 'g<C-q>', function() end, { desc = 'Control key test' })
for index = 1, 24 do
  vim.keymap.set('n', 'g<F' .. index .. '>', function() end, { desc = 'Overflow key ' .. index })
end
local view = require('which-key.view')
local state = require('which-key.state')
local config = require('which-key.config')
local result, failure, step = {}, nil, 0
local original_getchar = state.getchar
local function topline()
  return vim.api.nvim_win_call(view.view.win, function() return vim.fn.winsaveview().topline end)
end
-- Supply keyboard input to the real plugin loop. Plain headless stdin reaches EOF
-- in getcharstr(), so only that input source is replaced; the view, sorting,
-- buffer rendering and scroll dispatch below all use the installed plugin.
state.getchar = function()
  step = step + 1
  local ok, key = pcall(function()
    if step == 1 then
      view.show()
      assert(view.valid() and state.state.node.keys == 'g', 'The actual g popup must be open')
      local items = {}
      for _, node in ipairs(state.state.node:children()) do items[#items + 1] = view.item(node) end
      view.sort(items)
      assert(items[1].node.keys == 'gr' and items[1].desc == '+LSP', 'LSP r group must sort first')
      local lines = vim.api.nvim_buf_get_lines(view.view.buf, 0, -1, false)
      result.rendered = table.concat(lines, '\n')
      local _, columns = lines[1]:gsub('%-%>', '')
      assert(columns > 1, 'Wide terminal must render multiple compact columns')
      assert(result.rendered:match('^%s*r%s*%-%>%s*%+LSP'), 'The first rendered item must be r -> +LSP')
      assert(result.rendered:find('<C', 1, true), 'Control keys must render with ordinary text names: ' .. result.rendered)
      for _, char in ipairs(vim.fn.str2list(result.rendered, true)) do
        assert(not (char >= 0xE000 and char <= 0xF8FF), 'Popup must not contain private-use font icons')
      end
      assert(config.keys.scroll_down == '<C-D>' and config.keys.scroll_up == '<C-U>')
      result.top = topline()
      assert(vim.api.nvim_buf_line_count(view.view.buf) > vim.api.nvim_win_get_height(view.view.win), 'Fixture must have scrollable overflow')
      return '<C-d>'
    elseif step == 2 then
      result.down = topline()
      assert(result.down > result.top, 'C-d must scroll the open menu down')
      assert(state.state.node.keys == 'g', 'Scrolling must retain the g group')
      return '<C-u>'
    elseif step == 3 then
      result.up = topline()
      assert(result.up < result.down, 'C-u must scroll the open menu up')
      result.passed = true
      return '<Esc>'
    end
    error('Unexpected additional which-key input')
  end)
  if not ok then failure = tostring(key); key = '<Esc>' end
  return true, vim.api.nvim_replace_termcodes(key, true, false, true)
end
-- Script mode does not necessarily emit VimEnter; the command loads the plugin.
vim.cmd('WhichKey n g')
state.getchar = original_getchar
assert(not failure, failure)
assert(result.passed, vim.inspect(result))
print('whichkey_native: real g popup, r LSP first, text labels, compact columns, C-d/C-u scroll dispatch passed')
