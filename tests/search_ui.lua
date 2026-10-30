-- nvim --headless -u NONE -i NONE -l tests/search_ui.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. '/one/.git', 'p')
vim.fn.mkdir(temp .. '/one/src', 'p')
vim.fn.writefile({ '[package]' }, temp .. '/one/src/Cargo.toml')
vim.fn.mkdir(temp .. '/two/.git', 'p')
local real_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind) return kind == 'state' and (temp .. '/state') or real_stdpath(kind) end
vim.g.mapleader = ' '
local calls = { downloads = 0, fallback = 0, init = 0, roots = 0, opens = 0 }
local native_root, complete_download, native_version = nil, nil, '0.11.0'
local binary = temp .. '/libfff_nvim.test'
local function buffer(path)
  local buf = vim.fn.bufnr(path)
  if buf < 0 then buf = vim.api.nvim_create_buf(true, false); vim.api.nvim_buf_set_name(buf, path) end
  vim.api.nvim_set_current_buf(buf)
end
local function fake(name, value) package.loaded[name] = nil; package.preload[name] = function() return value end end
fake('telescope', { setup = function() end })
fake('telescope.builtin', { find_files = function(opts) calls.fallback = calls.fallback + 1; calls.fallback_root = opts.cwd end })
fake('fff.download', {
  get_binary_path = function() return binary end,
  ensure_downloaded = function(opts, callback)
    assert(opts.version == 'v0.11.0' and opts.force == true)
    calls.downloads = calls.downloads + 1
    complete_download = callback
  end,
})
fake('fff.rust', {
  health_check = function() return { version = native_version, file_picker = { base_path = native_root } } end,
  cleanup_file_picker = function() calls.cleanup = (calls.cleanup or 0) + 1 end,
})
local conf = {}
fake('fff.conf', { get = function() return conf end })
fake('fff.core', {
  ensure_initialized = function() if not native_root then native_root = conf.base_path; calls.init = calls.init + 1 end end,
  is_file_picker_initialized = function() return native_root ~= nil end,
})
fake('fff', {
  file_search = function(_, opts)
    if native_root ~= opts.cwd then native_root = opts.cwd; calls.roots = calls.roots + 1 end
    return { items = {} }
  end,
})
local picker = { state = { active = false } }
picker.open = function() picker.state.active = true; calls.opens = calls.opens + 1; return true end
fake('fff.picker_ui.picker_ui', picker)
local wk
fake('which-key', { setup = function(opts) wk = opts end })

buffer(temp .. '/one/src/main.cpp')
local search = require('config.search')
buffer(temp .. '/outside/main.rs')
assert(search.project_root() == vim.fn.getcwd(), 'without Git, the root must be cwd')
buffer(temp .. '/one/src/main.cpp')
assert(vim.fs.normalize(search.project_root()) == vim.fs.normalize(temp .. '/one'))
search.setup({})
vim.wait(20)
assert(search.native_status().status == 'downloading' and calls.downloads == 1)
search.find_files()
search.ensure_native(function(ok) assert(ok); calls.callback = true end)
assert(calls.fallback == 1 and calls.downloads == 1, 'pending download must fall back and be shared')
vim.fn.writefile({ 'test native marker' }, binary)
complete_download(true)
assert(calls.callback and search.native_status().status == 'ready')
search.find_files(); picker.state.active = false; search.find_files()
assert(calls.opens == 2 and calls.init == 1 and calls.roots == 0, 'same root must reuse the session index')
buffer(temp .. '/two/main.jai')
picker.state.active = false
search.find_files()
assert(calls.roots == 1 and calls.opens == 3, 'new project must change the index root once')
picker.open = function() error('intentional UI failure') end
search.find_files()
assert(calls.fallback == 2, 'picker failure must use Telescope')

-- A new session/module uses the version marker without downloading again.
package.loaded['config.search'] = nil
package.loaded['fff.rust'] = nil
local second = require('config.search')
second.ensure_native()
assert(second.native_status().status == 'ready' and calls.downloads == 1)
-- A loaded mismatched library is rejected, never overwritten inside this process.
package.loaded['config.search'] = nil
native_version = '0.12.0'
local mismatched = require('config.search')
mismatched.ensure_native()
assert(mismatched.native_status().status == 'failed' and calls.downloads == 1)

require('config.whichkey').setup({})
assert(wk.icons.mappings == false and wk.replace.key[1]('<C-d>') == '<C-d>')
assert(wk.sort[1]({ node = { keys = 'gr' } }) < wk.sort[1]({ node = { keys = 'gd' } }))
assert(wk.keys.scroll_down == '<C-d>' and wk.keys.scroll_up == '<C-u>')
assert(wk.layout.width.max == 32)

vim.api.nvim_exec_autocmds('VimLeavePre', {})
vim.fn.stdpath = real_stdpath
vim.fn.delete(temp, 'rf')
print('search_ui: native version pin, shared download, fallback, root reuse/switch, plain which-key labels passed')
