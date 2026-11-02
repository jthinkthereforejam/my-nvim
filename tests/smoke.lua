-- nvim --headless -c "lua dofile(vim.fn.stdpath('config') .. '/tests/smoke.lua')"
local failures, passed = {}, 0
local function check(name, callback)
  local ok, err = xpcall(callback, debug.traceback)
  if ok then
    passed = passed + 1
    print('PASS ' .. name)
  else
    failures[#failures + 1] = name .. ': ' .. tostring(err)
    print('FAIL ' .. name)
  end
end

check('Neovim version and editor display', function()
  local version = vim.version()
  assert(version.major == 0 and version.minor == 12 and version.patch == 6, 'expected 0.12.6')
  assert(vim.o.number and vim.o.relativenumber and vim.o.cursorline)
  assert(vim.o.signcolumn == 'yes:2', 'Git and diagnostic columns must remain fixed')
  assert(vim.g.mapleader == ' ')
  assert(vim.g.colors_name == 'everforest' and vim.o.background == 'dark')
  assert(vim.g.everforest_background == 'medium')
end)

check('Plugin lock matches installed revisions', function()
  local lock_path = vim.fs.joinpath(vim.fn.stdpath('config'), 'nvim-pack-lock.json')
  local lock = vim.json.decode(table.concat(vim.fn.readfile(lock_path), '\n'))
  assert(type(lock.plugins) == 'table' and next(lock.plugins), 'empty plugin lock')
  local count = 0
  for _, plugin in ipairs(vim.pack.get(nil, { info = false })) do
    if plugin.active then
      local pinned = assert(lock.plugins[plugin.spec.name], 'unlocked plugin: ' .. plugin.spec.name)
      assert(#pinned.rev == 40 and pinned.rev:match('^[0-9a-f]+$'), 'invalid revision')
      local actual = vim.system({ 'git', '-C', plugin.path, 'rev-parse', 'HEAD' }, { text = true }):wait()
      assert(actual.code == 0 and vim.trim(actual.stdout) == pinned.rev, 'revision differs: ' .. plugin.spec.name)
      count = count + 1
    end
  end
  assert(count > 0, 'no active plugins')
  local fff = assert(lock.plugins['fff.nvim'], 'FFF missing from lock')
  assert(fff.version == "'v0.11.0'", 'FFF must follow exactly v0.11.0')
  local gitsigns = assert(lock.plugins['gitsigns.nvim'], 'Gitsigns missing from lock')
  assert(gitsigns.version == "'v2.1.0'", 'Gitsigns must follow exactly v2.1.0')
end)

check('Git display configuration and entry points', function()
  local config = require('gitsigns.config').config
  assert(config.base == 'HEAD', 'Git signs must compare against HEAD')
  assert(config.signcolumn and config.attach_to_untracked, 'Git signs/untracked files must be enabled')
  for name, text in pairs({ add = '+', change = '~', delete = '_', topdelete = '^' }) do
    assert(config.signs[name].text == text, 'unexpected Git sign: ' .. name)
  end
  local commands = vim.api.nvim_get_commands({})
  for _, name in ipairs({ 'GitDiffToggle', 'GitChanges' }) do
    assert(commands[name], 'missing Git command: ' .. name)
  end
  for _, keys in ipairs({ ' gp', ' gd', ' gs', ' gt' }) do
    local mapping = vim.fn.maparg(keys, 'n', false, true)
    assert(mapping.callback or mapping.rhs and mapping.rhs ~= '', 'missing Git key: ' .. keys)
  end
end)

for language, source in pairs({
  c_sharp = 'class Example { static int Value = 42; }',
  c = 'int main(void) { return 0; }',
  cpp = 'class Example { public: int value = 42; };',
  rust = 'fn main() { let value = 42; }',
}) do
  check('Tree-sitter parses and highlights ' .. language, function()
    local parser = vim.treesitter.get_string_parser(source, language)
    local tree = assert(parser:parse()[1], 'no parse tree')
    assert(not tree:root():has_error(), 'syntax fixture did not parse')
    assert(vim.treesitter.query.get(language, 'highlights'), 'highlight query missing')
  end)
end

check('Four language servers configured and enabled', function()
  for _, name in ipairs({ 'clangd', 'rust_analyzer', 'roslyn', 'jailsp' }) do
    local server = assert(vim.lsp.config[name], 'missing ' .. name)
    assert(server.cmd, 'missing command: ' .. name)
    assert(vim.lsp.is_enabled(name), 'disabled: ' .. name)
  end
end)

check('Jai syntax and save formatting settings', function()
  assert(#vim.api.nvim_get_runtime_file('syntax/jai.vim', false) > 0, 'Jai syntax missing')
  assert(require('jai.config').get().format_on_save == false)
end)

check('Blink leaves command line completion native', function()
  local config = require('blink.cmp.config')
  assert(config.cmdline.enabled == false, 'blink command line completion enabled')
  assert(vim.o.wildmenu and vim.o.wildoptions:find('pum', 1, true))
end)

check('Saving C buffer preserves content', function()
  local filename = vim.fn.tempname() .. '.c'
  local previous = vim.api.nvim_get_current_buf()
  local buffer
  local ok, err = pcall(function()
    vim.cmd.edit(vim.fn.fnameescape(filename))
    buffer = vim.api.nvim_get_current_buf()
    local text = { 'int main(){return 0;}' }
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, text)
    vim.cmd.write()
    assert(vim.deep_equal(vim.fn.readfile(filename), text), 'save changed source text')
  end)
  if previous and vim.api.nvim_buf_is_valid(previous) then vim.api.nvim_set_current_buf(previous) end
  if buffer and vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
  vim.fn.delete(filename)
  assert(ok, err)
end)

check('Machine configuration ignored; lock remains shareable', function()
  local root = assert(vim.uv.fs_realpath(vim.fn.stdpath('config')))
  local ignored = vim.system({ 'git', '-C', root, 'check-ignore', 'local.lua' }, { text = true }):wait()
  assert(ignored.code == 0, 'local.lua is not ignored')
  local lock = vim.system({ 'git', '-C', root, 'check-ignore', 'nvim-pack-lock.json' }, { text = true }):wait()
  assert(lock.code == 1, 'plugin lock must not be ignored')
end)

print(('Smoke checks: %d passed, %d failed'):format(passed, #failures))
if #failures > 0 then
  vim.api.nvim_err_writeln(table.concat(failures, '\n\n'))
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
