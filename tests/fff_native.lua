-- Run with the bootstrapped configuration, once per process:
-- nvim --headless -u ./init.lua -i NONE -l tests/fff_native.lua
-- This test does not install or replace any native library.
assert(vim.g.my_nvim_ready, 'Start this test with the my-nvim configuration enabled')
local search = require('config.search')
assert(vim.wait(10000, function()
  local status = search.native_status().status
  return status == 'ready' or status == 'failed'
end, 20), 'Native startup timed out')
assert(search.native_status().status == 'ready', vim.inspect(search.native_status()))
local native = require('fff.rust')
assert(native.health_check().version == '0.11.0')
assert(not native.health_check().file_picker.initialized, 'Every new process must begin without a file index')

local temp = vim.fn.tempname()
for _, name in ipairs({ 'one', 'two' }) do
  local root = temp .. '/' .. name
  vim.fn.mkdir(root .. '/src', 'p')
  local git = vim.system({ 'git', 'init', '--quiet', root }, { text = true }):wait()
  assert(git.code == 0, git.stderr)
  vim.fn.writefile({ '// ' .. name }, root .. '/src/main.cpp')
end
local initializations, explicit_scans = 0, 0
local original_init, original_scan = native.init_file_picker, native.scan_files
native.init_file_picker = function(...)
  initializations = initializations + 1
  return original_init(...)
end
native.scan_files = function(...)
  explicit_scans = explicit_scans + 1
  return original_scan(...)
end
local function canonical(path)
  path = vim.fs.normalize(vim.uv.fs_realpath(path) or path):gsub('[/\\]+$', '')
  return vim.fn.has('win32') == 1 and path:lower() or path
end
local function show(root)
  local buf = vim.fn.bufnr(root .. '/src/main.cpp')
  if buf < 0 then
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, root .. '/src/main.cpp')
  end
  vim.api.nvim_set_current_buf(buf)
  assert(canonical(search.project_root()) == canonical(root))
  search.find_files()
  local picker = require('fff.picker_ui.picker_ui')
  assert(picker.state.active, 'Real FFF UI must open rather than Telescope fallback')
  assert(native.wait_for_initial_scan(10000), 'Initial project scan timed out')
  local health = native.health_check(root)
  assert(health.file_picker.initialized and canonical(health.file_picker.base_path) == canonical(root))
  assert(health.file_picker.indexed_files >= 1, 'Project scan did not discover any files')
  local matches = require('fff').file_search('main.cpp', { cwd = root }).items
  assert(#matches == 1 and matches[1].relative_path == 'src/main.cpp', vim.inspect(matches))
  picker.close()
  vim.cmd.stopinsert()
  assert(not picker.state.active, 'FFF UI must close cleanly')
  return health.file_picker.indexed_files
end

local first_count = show(temp .. '/one')
local second_count = show(temp .. '/one')
assert(first_count == second_count and initializations == 1 and explicit_scans == 0,
  'Repeated picker opens must reuse the existing index without an explicit rescan')
show(temp .. '/two')
assert(initializations == 1 and explicit_scans == 0, 'Project switching must use the native root change API')
show(temp .. '/two')
assert(initializations == 1 and explicit_scans == 0)

-- Force an unavailable FFF loader while retaining the real Telescope picker.
local original_search, original_download = package.loaded['config.search'], package.loaded['fff.download']
local original_preload = package.preload['fff.download']
package.loaded['config.search'], package.loaded['fff.download'] = nil, nil
package.preload['fff.download'] = function() error('intentional missing native installation') end
local fallback = require('config.search')
fallback.find_files()
assert(vim.bo.filetype == 'TelescopePrompt', 'Unavailable native must open the actual Telescope file picker')
local prompt = vim.api.nvim_get_current_buf()
local telescope_picker = require('telescope.actions.state').get_current_picker(prompt)
assert(canonical(telescope_picker.cwd) == canonical(temp .. '/two'), 'Fallback must search the same project')
require('telescope.actions').close(prompt)
package.loaded['config.search'], package.loaded['fff.download'] = original_search, original_download
package.preload['fff.download'] = original_preload

native.cleanup_file_picker()
vim.wait(100)
native.init_file_picker, native.scan_files = original_init, original_scan
assert(vim.fn.delete(temp, 'rf') == 0, 'Could not clean up temporary projects')
print('fff_native: exact 0.11.0 native, cold process index, real UI open/close, session reuse, project switch passed')
