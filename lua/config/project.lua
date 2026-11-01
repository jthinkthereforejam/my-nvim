-- Explicit project roots belong to one Neovim instance. User-facing open
-- actions only launch independent processes; only startup activates a root.
local M = {}
local history = require('config.project_history')
local active_root, pending_root, machine, startup_done
local function notify_error(err) vim.notify(tostring(err), vim.log.levels.ERROR) end
function M.root() return active_root end
function M.history() return history.list() end
function M.forget(root) return history.remove(root) end
local function valid_path(path, kind)
  local ok, normalized = pcall(history.normalize, path)
  if not ok then return nil, normalized end
  local stat = vim.uv.fs_stat(normalized)
  if not stat or stat.type ~= kind then return nil, 'Path is not an existing ' .. kind .. ': ' .. normalized end
  return normalized
end
local function launch(kind, path)
  local ok, err = require('config.project_native').launch(kind, path)
  if not ok then notify_error(err or 'Could not launch Neovim') end
  return ok, err
end
function M.open(path)
  if not path or path == '' then
    require('config.project_native').choose_folder(function(chosen, err)
      if err then notify_error(err) elseif chosen then M.open(chosen) end
    end)
    return
  end
  local root, err = valid_path(path, 'directory')
  if not root then notify_error(err); return false, err end
  return launch('project', root)
end
function M.open_file(path)
  if not path or path == '' then
    require('config.project_native').choose_file(function(chosen, err)
      if err then notify_error(err) elseif chosen then M.open_file(chosen) end
    end)
    return
  end
  local file, err = valid_path(path, 'file')
  if not file then notify_error(err); return false, err end
  return launch('file', file)
end
function M.home() return launch('home') end
function M.save_session()
  local ok, result = pcall(require('config.project_session').save)
  if not ok then notify_error(result); return false end
  if not result then vim.notify('Open a project and a file before saving its session.', vim.log.levels.INFO) end
  return result
end
local function empty_project(root)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'project-empty://' .. history.key(root))
  vim.bo[buf].filetype = 'project_empty'
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '', '  ' .. vim.fs.basename(root), '  ' .. root, '',
    '  当前项目还没有可浏览的文件。', '',
    '  f  搜索项目文件', '  o  打开另一个文件夹（新窗口）', '  p  最近项目',
    '  Ctrl+j  打开项目终端', '', '  用 :edit 文件名 创建文件，保存后即可开始编辑。',
  })
  vim.bo[buf].modifiable = false
  vim.api.nvim_set_current_buf(buf)
  vim.keymap.set('n', 'f', function() require('config.search').find_files() end, { buffer = buf, desc = 'Find project files' })
  vim.keymap.set('n', 'o', function() M.open() end, { buffer = buf, desc = 'Open folder in new window' })
  vim.keymap.set('n', 'p', M.recent, { buffer = buf, desc = 'Recent projects' })
end
local function has_files(root)
  local pending, visited = { root }, 0
  while #pending > 0 do
    local directory = table.remove(pending)
    local scan = vim.uv.fs_scandir(directory)
    if scan then
      while true do
        local name, kind = vim.uv.fs_scandir_next(scan)
        if not name then break end
        if name ~= '.git' and name ~= '.DS_Store' then
          if kind == 'file' then return true end
          if kind == 'directory' then pending[#pending + 1] = vim.fs.joinpath(directory, name) end
        end
      end
    end
    visited = visited + 1
    -- Large trees are left to FFF's asynchronous, ignore-aware indexer.
    if visited >= 256 then return true end
  end
  return false
end
function M.activate(path, options)
  options = options or {}
  local root, err = valid_path(path, 'directory')
  if not root then error(err) end
  active_root = root
  vim.fn.chdir(root)
  local session = require('config.project_session')
  session.configure(root)
  local restored = options.restore ~= false and session.load() or false
  vim.fn.chdir(root)
  history.record(root)
  vim.api.nvim_exec_autocmds('User', { pattern = 'ProjectOpened', modeline = false, data = { root = root } })
  if not restored and options.pick ~= false and #vim.api.nvim_list_uis() > 0 then
    vim.schedule(function()
      if active_root == root then
        if has_files(root) then require('config.search').find_files() else empty_project(root) end
      end
    end)
  end
  return restored
end
function M.recent()
  local items = M.history()
  if #items == 0 then vim.notify('No recent projects yet. Use ProjectOpen to choose a folder.', vim.log.levels.INFO); return end
  local actions = require('telescope.actions')
  local state = require('telescope.actions.state')
  local picker
  picker = require('telescope.pickers').new({}, {
    prompt_title = '最近项目（Enter 新窗口打开 / Ctrl+d 移除记录）',
    finder = require('telescope.finders').new_table({ results = items,
      entry_maker = function(item)
        local label = ('%s%s  %s'):format(item.exists and '' or '[Unavailable] ', item.name, item.root)
        return { value = item, display = label, ordinal = item.name .. ' ' .. item.root }
      end,
    }),
    sorter = require('telescope.config').values.generic_sorter({}),
    attach_mappings = function(prompt, map)
      local choose = function()
        local selected = state.get_selected_entry()
        actions.close(prompt)
        if selected then M.open(selected.value.root) end
      end
      for _, name in ipairs({ 'select_default', 'select_horizontal', 'select_vertical', 'select_tab' }) do
        actions[name]:replace(choose)
      end
      map({ 'n', 'i' }, '<C-d>', function()
        local selected = state.get_selected_entry()
        if not selected then return end
        history.remove(selected.value.root)
        picker:refresh(require('telescope.finders').new_table({ results = M.history(),
          entry_maker = function(item)
            local label = ('%s  %s'):format(item.name, item.root)
            return { value = item, display = label, ordinal = label }
          end,
        }), { reset_prompt = false })
      end)
      return true
    end,
  })
  picker:find()
end
function M.prepare(value)
  machine = value or {}
  history.setup(machine.project)
  if vim.g.my_nvim_project_launch == 1 or vim.g.my_nvim_project_launch == true then
    pending_root = history.normalize(vim.fn.getcwd())
  elseif vim.fn.argc(-1) == 1 then
    local path = vim.fn.argv(0)
    if vim.fn.isdirectory(path) == 1 then
      pending_root = history.normalize(path)
      -- A directory is a workspace request, not a netrw file buffer.
      vim.cmd('silent! %argdelete')
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= '' and not vim.bo[buf].modified and history.normalize(name) == pending_root then
          vim.api.nvim_buf_delete(buf, { force = false })
        end
      end
    end
  end
  if pending_root then active_root = pending_root; vim.fn.chdir(pending_root) end
end
function M.setup(value)
  machine = value or machine or {}
  require('config.project_native').setup(machine)
  require('config.project_session').setup()
  local function start()
    if startup_done then return end
    startup_done = true
    local ok, err = pcall(history.seed)
    if not ok then vim.notify('Could not seed project history: ' .. tostring(err), vim.log.levels.WARN) end
    if pending_root then
      local target = pending_root
      pending_root = nil
      local activated, why = pcall(M.activate, target, { restore = true })
      if not activated then notify_error(why) end
    end
  end
  local group = vim.api.nvim_create_augroup('my-nvim-project', { clear = true })
  if vim.v.vim_did_enter == 1 then vim.schedule(start)
  else vim.api.nvim_create_autocmd('VimEnter', { group = group, once = true, callback = function() vim.schedule(start) end }) end
  vim.api.nvim_create_user_command('ProjectOpen', function(args) M.open(args.args) end,
    { nargs = '?', complete = 'dir', desc = 'Open a folder in a new Neovim window', force = true })
  for name, callback in pairs({ ProjectRecent = M.recent, ProjectHome = M.home, ProjectSaveSession = M.save_session }) do
    vim.api.nvim_create_user_command(name, callback, { desc = name, force = true })
  end
  for key, entry in pairs({ po = { function() M.open() end, 'Open folder in new window' },
    pp = { M.recent, 'Recent projects' }, ph = { M.home, 'New welcome window' }, ps = { M.save_session, 'Save project session' } }) do
    vim.keymap.set('n', '<leader>' .. key, entry[1], { desc = entry[2], silent = true })
  end
end
return M
