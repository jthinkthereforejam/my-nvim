-- nvim --headless -u NONE -i NONE -l tests/cmdline_native.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
require('config.cmdline').setup({})
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. '/apples/deep-one', 'p')
vim.fn.mkdir(temp .. '/apples/deep-two', 'p')
vim.fn.mkdir(temp .. '/apricots', 'p')
local samples = {}
vim.keymap.set('c', '<F12>', function()
  samples[#samples + 1] = { line = vim.fn.getcmdline():gsub('\\', '/'), info = vim.fn.cmdcomplete_info() }
  return ''
end, { expr = true })
local keys = ':edit ' .. vim.fn.fnameescape(temp:gsub('\\', '/') .. '/a')
  .. '<Tab><F12><Down><F12><Tab><F12><Esc>'
vim.fn.feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt')
assert(#samples == 3, vim.inspect(samples))
assert(samples[1].line:match('/ap$'), 'Tab must insert the shared prefix: ' .. vim.inspect(samples))
assert(samples[2].line:match('/apples[/\\]$'), 'Down must select a directory, not descend: ' .. vim.inspect(samples))
assert(samples[3].line:match('/apples[/\\]deep%-'), 'Tab must accept and complete the next level: ' .. vim.inspect(samples))
-- A selected file is accepted without running :edit.
vim.fn.writefile({ 'one' }, temp .. '/apples/deep-one/item-a.txt')
vim.fn.writefile({ 'two' }, temp .. '/apples/deep-one/item-b.txt')
samples = {}
keys = ':edit ' .. vim.fn.fnameescape(temp:gsub('\\', '/') .. '/apples/deep-one/item-')
  .. '<Tab><Down><Tab><F12><Esc>'
vim.fn.feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt')
assert(samples[1].line:match('item%-a%.txt$'), 'Tab must accept the selected file')
assert(vim.api.nvim_buf_get_name(0) == '', 'accepting a candidate must not execute :edit')
-- Escaping paths with spaces still belongs to the native completion engine.
vim.fn.mkdir(temp .. '/space dir', 'p')
vim.fn.writefile({ 'one' }, temp .. '/space dir/item-a.txt')
vim.fn.writefile({ 'two' }, temp .. '/space dir/item-b.txt')
samples = {}
keys = ':edit ' .. vim.fn.fnameescape(temp:gsub('\\', '/') .. '/space dir/item-')
  .. '<Tab><Down><Tab><F12><Esc>'
vim.fn.feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt')
assert(samples[1].line:match('item%-a%.txt$'), 'paths with spaces must accept normally')
-- Outside the popup, arrow keys continue to navigate Ex history.
vim.fn.histadd('cmd', 'echo 123456789')
samples = {}
vim.fn.feedkeys(vim.api.nvim_replace_termcodes(':<Up><F12><Esc>', true, false, true), 'xt')
assert(samples[1].line == 'echo 123456789', 'Up must preserve command history outside completion')
vim.fn.delete(temp, 'rf')
print('cmdline_native: real native common prefix, arrow selection, directory descent, file acceptance passed')
