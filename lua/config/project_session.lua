-- persistence.nvim handles native sessions; project hashes keep their names
-- short on Windows and atomic publication protects concurrent readers.
local M = {}
local history = require('config.project_history')
local active, session_file, current_file
local session_options = { 'buffers', 'curdir', 'folds', 'tabpages', 'winsize' }
local function ordinary_files()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].buftype == '' and name ~= '' and vim.fn.isdirectory(name) == 0 then return true end
  end
  return false
end
function M.configure(root)
  active = root
  local directory = vim.fs.joinpath(history.base_dir(), 'sessions') .. '/'
  session_file = directory .. history.key(root) .. '.vim'
  current_file = session_file
  local persistence = require('persistence')
  persistence.setup({ dir = directory, branch = false, need = 1 })
  -- This pinned plugin routes save/load through current(). Its default filename
  -- encodes the complete cwd, which can exceed MAX_PATH on Windows. The adapter
  -- also keeps the selected folder's session stable after a manual :cd.
  persistence.current = function() return current_file end
  persistence.stop()
  vim.opt.sessionoptions = session_options
end
function M.file() return session_file end
function M.save()
  if not active or not ordinary_files() then return false end
  local persistence = require('persistence')
  local temporary = session_file .. '.' .. vim.uv.os_getpid() .. '-' .. tostring(vim.uv.hrtime()) .. '.tmp'
  current_file = temporary
  local ok, err = xpcall(function()
    vim.opt.sessionoptions = session_options
    persistence.fire('SavePre')
    -- Tracked terminals temporarily cover their editor buffers in-place. Save
    -- the code layout without closing jobs or changing the user's visible UI.
    require('config.terminal').with_editors(function() persistence.save() end)
  end, debug.traceback)
  current_file = session_file
  if ok then
    local published, why = vim.uv.fs_rename(temporary, session_file)
    ok, err = published ~= nil, why
  end
  if vim.uv.fs_stat(temporary) then vim.uv.fs_unlink(temporary) end
  if not ok then error('Could not save project session: ' .. tostring(err)) end
  persistence.fire('SavePost')
  return true
end
function M.load()
  if not session_file or vim.fn.filereadable(session_file) ~= 1 then return false end
  local before = vim.v.errmsg
  vim.v.errmsg = ''
  local ok, err = pcall(require('persistence').load)
  local load_error = vim.v.errmsg
  vim.v.errmsg = before
  if not ok or load_error ~= '' then
    vim.notify('Project session could not be restored: ' .. tostring(err or load_error), vim.log.levels.WARN)
    return false
  end
  return ordinary_files()
end
function M.setup()
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('my-nvim-project-session', { clear = true }),
    callback = function()
      local ok, err = pcall(M.save)
      if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
    end,
  })
end
return M
