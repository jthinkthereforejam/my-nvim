-- The Lua plugin and its native library deliberately share one exact release.
local M = {}
local VERSION = 'v0.11.0'
local state = { status = 'unchecked', callbacks = {}, root = nil, error = nil }
local marker = vim.fs.joinpath(vim.fn.stdpath('state'), 'my-nvim', 'fff-native.json')

local function canonical(path)
  path = vim.fs.normalize(vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ':p')):gsub('[/\\]+$', '')
  return vim.fn.has('win32') == 1 and path:lower() or path
end

function M.project_root()
  local project = package.loaded['config.project']
  if project and project.root() then return project.root() end
  local name = vim.api.nvim_buf_get_name(0)
  local start = vim.bo.buftype == '' and name ~= '' and vim.fs.dirname(name) or vim.fn.getcwd()
  return vim.fs.root(start, '.git') or vim.fn.getcwd()

end

local function finish(ok, err)
  state.status = ok and 'ready' or 'failed'
  state.error = err
  local callbacks = state.callbacks
  state.callbacks = {}
  for _, callback in ipairs(callbacks) do
    local success, callback_error = pcall(callback, ok, err)
    if not success then vim.notify(tostring(callback_error), vim.log.levels.ERROR) end
  end
  if not ok then
    vim.notify_once('FFF unavailable; using Telescope. ' .. tostring(err), vim.log.levels.WARN)
  end
end

local function fingerprint(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return nil end
  return { version = VERSION, path = canonical(path), size = stat.size,
    modified = stat.mtime.sec, modified_ns = stat.mtime.nsec }
end

local function read_marker()
  local ok, lines = pcall(vim.fn.readfile, marker)
  if not ok then return nil end
  local decoded, value = pcall(vim.json.decode, table.concat(lines, '\n'))
  return decoded and value or nil
end

local function verify_native()
  local native = require('fff.rust')
  local health = native.health_check(M.project_root())
  if health.version ~= VERSION:sub(2) then
    error(('Expected FFF %s, loaded %s. Restart Neovim after reinstalling its native library.')
      :format(VERSION, tostring(health.version)))
  end
  return native
end

--- Ensure the native release is installed. Concurrent callers share one download.
--- @param callback? fun(ok: boolean, error?: string)
function M.ensure_native(callback)
  if state.status == 'ready' or state.status == 'failed' then
    if callback then callback(state.status == 'ready', state.error) end
    return
  end
  if callback then table.insert(state.callbacks, callback) end
  if state.status == 'downloading' then return end
  state.status = 'downloading'

  local ok, download = pcall(require, 'fff.download')
  if not ok then finish(false, tostring(download)); return end
  local path = download.get_binary_path()
  state.binary = path

  local function verify_and_finish()
    local loaded, err = pcall(verify_native)
    if not loaded then finish(false, tostring(err)); return end
    local saved, save_err = pcall(function()
      vim.fn.mkdir(vim.fs.dirname(marker), 'p')
      local identity = assert(fingerprint(path), 'FFF binary is missing')
      vim.fn.writefile({ vim.json.encode(identity) }, marker)
    end)
    if not saved then vim.notify('Could not save FFF version marker: ' .. tostring(save_err), vim.log.levels.WARN) end
    finish(true)
  end

  -- Never overwrite a loaded DLL. Health checks still reject a different version.
  if package.loaded['fff.rust'] then verify_and_finish(); return end
  if vim.deep_equal(read_marker(), fingerprint(path)) and fingerprint(path) then
    verify_and_finish()
    return
  end

  local started, err = pcall(download.ensure_downloaded, { version = VERSION, force = true }, function(success, why)
    if not success then finish(false, why); return end
    verify_and_finish()
  end)
  if not started then finish(false, tostring(err)) end
end

function M.native_status()
  return { status = state.status, version = VERSION, binary = state.binary, error = state.error, root = state.root }
end

local function telescope_files(root)
  require('telescope.builtin').find_files({ cwd = root })
end

function M.find_files()
  local root = M.project_root()
  if state.status ~= 'ready' then
    M.ensure_native()
    telescope_files(root)
    return
  end
  local ok, err = pcall(function()
    local conf = require('fff.conf').get()
    if not state.root then conf.base_path = root end
    local core = require('fff.core')
    core.ensure_initialized()
    if not core.is_file_picker_initialized() then error('File index could not initialize') end

    -- The public API canonicalizes roots and waits only when changing projects.
    -- No scan_files()/clear_cache() is called when opening the same project again.
    require('fff').file_search('', { cwd = root, max_results = 1 })
    local health = require('fff.rust').health_check(root)
    if not health.file_picker or canonical(health.file_picker.base_path or '') ~= canonical(root) then
      error('File index has not switched to the requested project yet')
    end
    state.root = root
    local picker = require('fff.picker_ui.picker_ui')
    if picker.open({ cwd = root }) == false or not picker.state.active then error('File picker could not open') end
  end)
  if not ok then
    vim.notify_once('FFF search failed; using Telescope. ' .. tostring(err), vim.log.levels.WARN)
    telescope_files(root)
  end
end

function M.setup(_machine)
  -- Set lazy_sync before vim.pack.add too: plugin/fff.lua must not load native early.
  vim.g.fff = vim.tbl_deep_extend('force', vim.g.fff or {}, {
    lazy_sync = true, base_path = M.project_root(), prompt = 'Files> ',
    enable_home_dir_scanning = false, enable_fs_root_scanning = false,
  })
  require('telescope').setup({ defaults = { selection_caret = '> ', entry_prefix = '  ' } })
  local function map(keys, callback, desc)
    vim.keymap.set('n', keys, callback, { desc = desc, silent = true })
  end
  map('<leader>sf', M.find_files, 'Find project files (FFF)')
  map('<leader>sF', function() telescope_files(M.project_root()) end, 'Find files (Telescope)')
  map('<leader>sg', function() require('telescope.builtin').live_grep({ cwd = M.project_root() }) end, 'Search project text')
  map('<leader>sw', function() require('telescope.builtin').grep_string({ cwd = M.project_root() }) end, 'Search current word')
  map('<leader>sh', function() require('telescope.builtin').help_tags() end, 'Search help')
  map('<leader>sr', function() require('telescope.builtin').resume() end, 'Resume Telescope search')
  map('<leader><leader>', function() require('telescope.builtin').buffers() end, 'Find open buffers')

  vim.api.nvim_create_user_command('FFFInstall', function()
    if state.status ~= 'downloading' and state.status ~= 'ready' then state.status = 'unchecked' end
    M.ensure_native(function(success)
      if success then vim.notify('FFF ' .. VERSION .. ' native library ready') end
    end)
  end, { desc = 'Install or retry the locked FFF native library', force = true })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('my-nvim-fff', { clear = true }),
    callback = function()
      local native = package.loaded['fff.rust']
      if native and native.cleanup_file_picker then pcall(native.cleanup_file_picker) end
    end,
  })
  vim.schedule(function() M.ensure_native() end)
end

return M
