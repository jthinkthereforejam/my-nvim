-- One optional project sidebar. Search, terminal jobs and project roots remain
-- owned by their existing modules; Snacks supplies the directory tree only.
local M = {}
local api = vim.api
local main_by_tab, owned_by_tab = {}, {}
local closing = false

local function valid(win)
  return win and api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative == ''
end
local function editor(win)
  if not valid(win) or vim.w[win].snacks_layout then return false end
  local kind = vim.bo[api.nvim_win_get_buf(win)].buftype
  return kind == '' or kind == 'terminal'
end
local function picker()
  local tab = api.nvim_get_current_tabpage()
  local owned = owned_by_tab[tab]
  if owned and not owned.closed then return owned end
  owned_by_tab[tab] = nil
  local snacks = package.loaded['snacks']
  if not snacks or not package.loaded['snacks.picker.core.picker'] then return nil end
  return snacks.picker.get({ source = 'explorer' })[1]
end
local function remember(win)
  if editor(win) then main_by_tab[api.nvim_win_get_tabpage(win)] = win end
end
local function create_main(p)
  local anchor = p and p.list and p.list.win.win or api.nvim_get_current_win()
  if not valid(anchor) then anchor = api.nvim_get_current_win() end
  api.nvim_set_current_win(anchor)
  vim.cmd('rightbelow vsplit')
  local win = api.nvim_get_current_win()
  -- A split initially shares the tree's buffer, options and window variables.
  -- Restore a normal editor rather than leaving a sidebar-styled scratch pane.
  for name in pairs(vim.fn.getwinvar(win, '')) do
    if name:match('^snacks_') then pcall(api.nvim_win_del_var, win, name) end
  end
  api.nvim_win_set_buf(win, api.nvim_create_buf(true, false))
  for name, info in pairs(api.nvim_get_all_options_info()) do
    if info.scope == 'win' then
      pcall(api.nvim_set_option_value, name, api.nvim_get_option_value(name, { scope = 'global' }), { win = win })
    end
  end
  remember(win)
  return win
end
local function main_window(p)
  local tab = api.nvim_get_current_tabpage()
  local current = api.nvim_get_current_win()
  local preferred = main_by_tab[tab]
  if editor(current) then preferred = current end
  if not editor(preferred) and p then preferred = p.main end
  if not editor(preferred) then
    for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
      if editor(win) then preferred = win; break end
    end
  end
  -- The welcome/empty-project page can be used as the first editor target.
  if not editor(preferred) then
    preferred = nil
    for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
      local ft = vim.bo[api.nvim_win_get_buf(win)].filetype
      if valid(win) and not vim.w[win].snacks_layout and (ft == 'snacks_dashboard' or ft == 'project_empty') then
        preferred = win; break
      end
    end
  end
  if not valid(preferred) or vim.w[preferred].snacks_layout then preferred = create_main(p) end
  main_by_tab[tab] = preferred
  if p then p._main:set(preferred) end
  return preferred
end
local function to_main(p, open_file)
  local win = main_window(p)
  api.nvim_set_current_win(win)
  if open_file and vim.bo.buftype == 'terminal' then
    local terminal = require('config.terminal')
    if terminal.status().visible then
      terminal.toggle('n')
    else
      -- A manually created :terminal has no managed origin. Hide it without
      -- accidentally asking the terminal module to create a second shell.
      local old = api.nvim_get_current_buf()
      local hidden, bufhidden = vim.o.hidden, vim.bo[old].bufhidden
      vim.o.hidden, vim.bo[old].bufhidden = true, 'hide'
      local ok, err = pcall(api.nvim_win_set_buf, win, api.nvim_create_buf(true, false))
      vim.o.hidden = hidden
      if api.nvim_buf_is_valid(old) then vim.bo[old].bufhidden = bufhidden end
      if not ok then error(err) end
    end
  end
  return win
end
local function guard_close(p)
  if p._my_nvim_close_guard then return end
  p._my_nvim_close_guard = true
  local finder, native_close = p.finder, p.finder.close
  finder.close = function(self)
    -- The pinned finder done handlers consult self.task (not their own task).
    -- Native close installs a completed, non-aborted nop before older aborted
    -- searches finish, making them touch a cleared picker.matcher. Retire this
    -- one explorer's finder with an actual cancelled task instead. No global
    -- plugin objects or installed sources are changed.
    local retired = require('snacks.picker.util.async').new(function() end)
    retired:abort()
    native_close(self)
    self.task = retired
  end
end
function M.close(p)
  p = p or picker()
  if not p or p.closed then return end
  main_window(p) -- ensure closing the last sidebar cannot quit the tab/process
  p:close()
end
local function confirm(p, item, action)
  if not item then return end
  if api.nvim_get_mode().mode:sub(1, 1) == 'i' then
    vim.cmd.stopinsert()
    vim.schedule(function() if not p.closed then confirm(p, item, action) end end)
    return
  end
  local actions = require('snacks.explorer.actions')
  if item.dir then return actions.actions.confirm(p, item, action) end
  if p.input.filter.meta.searching then actions.update(p, { target = item.file }) end
  to_main(p, true)
  require('snacks.picker.actions').jump(p, item, action)
end
local function terminal(p)
  vim.cmd.stopinsert()
  to_main(p)
  require('config.terminal').toggle('n')
end
local function format(item, p)
  local f = require('snacks.picker.format')
  local ret = item.parent and f.tree(item, p) or {}
  ret[#ret + 1] = { item.dir and (item.open and '[-] ' or '[+] ') or '    ', 'SnacksPickerDirectory' }
  if item.status then vim.list_extend(ret, f.file_git_status(item, p)) end
  if item.severity then vim.list_extend(ret, f.severity(item, p)) end
  vim.list_extend(ret, f.filename(item, p))
  return ret
end
-- Called while configuring Snacks, before its automatic setup can run.
function M.options()
  local function file_action(name)
    return function(p, item, action) return require('config.explorer_files').actions[name](p, item, action) end
  end
  local actions = {
    confirm = confirm,
    safe_close = M.close,
    project_terminal = terminal,
    focus_main = function(p) vim.cmd.stopinsert(); to_main(p) end,
  }
  for _, name in ipairs({ 'explorer_add', 'explorer_rename', 'explorer_move', 'explorer_del', 'explorer_copy', 'explorer_paste' }) do
    actions[name] = file_action(name)
  end
  return {
    ignored = true, hidden = true, exclude = { '.git', '**/.git/**' },
    follow_file = true, watch = true, focus = 'list', auto_close = false,
    jump = { close = false }, prompt = '> ', title = 'Files', format = format,
    layout = { preset = 'sidebar', preview = false, layout = { width = 40, min_width = 40 } },
    icons = {
      files = { enabled = false }, git = { enabled = false },
      tree = { vertical = '| ', middle = '|-', last = '`-' },
      ui = { live = '*', selected = '[x]', unselected = '[ ]' },
      diagnostics = { Error = 'E', Warn = 'W', Info = 'I', Hint = 'H' },
      keymaps = { nowait = '' },
    },
    config = function(opts)
      opts = require('snacks.picker.source.explorer').setup(opts)
      opts.actions = vim.tbl_extend('force', opts.actions or {}, actions)
      return opts
    end,
    on_show = function(p)
      p._my_nvim_tab = p._my_nvim_tab or api.nvim_get_current_tabpage()
      owned_by_tab[p._my_nvim_tab] = p
      guard_close(p)
      local main = main_window(p)
      for _, name in ipairs({ 'list', 'input' }) do
        local w = p[name] and p[name].win
        if w and w:valid() then
          vim.bo[w.buf].buflisted = false
          vim.b[w.buf].my_nvim_explorer = true
        end
      end
      p._main:set(main)
    end,
    on_close = function(p)
      if owned_by_tab[p._my_nvim_tab] == p then owned_by_tab[p._my_nvim_tab] = nil end
      if vim.v.exiting ~= nil and vim.v.exiting ~= vim.NIL then return end
      if not closing then
        closing = true
        main_window(p)
        closing = false
      end
    end,
    win = {
      input = { keys = {
        ['<Esc>'] = { 'safe_close', mode = { 'n', 'i' } },
        ['<C-j>'] = { 'project_terminal', mode = { 'n', 'i' } },
        ['<C-t>'] = false,
        ['<C-l>'] = { 'focus_main', mode = { 'n', 'i' } },
      } },
      list = { keys = {
        ['q'] = 'safe_close', ['<Esc>'] = 'safe_close',
        ['<C-j>'] = 'project_terminal', ['<C-l>'] = 'focus_main',
        ['<C-t>'] = false, ['<C-c>'] = false, ['<leader>/'] = false,
        ['?'] = 'toggle_help_list',
      } },
    },
  }
end
function M.open()
  local p = picker()
  if p then p:focus('list'); return p end
  local win = main_window()
  api.nvim_set_current_win(win)
  local root = require('config.search').project_root()
  remember(win)
  local opened = require('snacks').explorer({ cwd = root })
  opened._my_nvim_tab = api.nvim_get_current_tabpage()
  owned_by_tab[opened._my_nvim_tab] = opened
  guard_close(opened)
  return opened
end
function M.toggle()
  local p = picker()
  if p then M.close(p) else M.open() end
end
function M.focus()
  local p = picker()
  if not p then return M.open() end
  if p:is_focused() then
    to_main(p)
    if vim.bo.buftype == 'terminal' then vim.cmd.startinsert() end
  else
    remember(api.nvim_get_current_win())
    p._main:set(main_window(p))
    p:focus('list')
  end
end
function M.status()
  local p = picker()
  return { visible = p ~= nil, picker = p, window = p and p.list.win.win or nil,
    main_win = p and p.main or main_by_tab[api.nvim_get_current_tabpage()], root = p and p:cwd() or nil }
end
function M.setup()
  local group = api.nvim_create_augroup('my-nvim-explorer', { clear = true })
  api.nvim_create_autocmd('WinEnter', { group = group, callback = function() remember(api.nvim_get_current_win()) end })
  api.nvim_create_autocmd('TabClosed', { group = group, callback = function()
    for tab in pairs(main_by_tab) do
      if not api.nvim_tabpage_is_valid(tab) then main_by_tab[tab], owned_by_tab[tab] = nil, nil end
    end
  end })
  api.nvim_create_user_command('ExplorerToggle', M.toggle, { desc = 'Toggle project file tree', force = true })
  api.nvim_create_user_command('ExplorerFocus', M.focus, { desc = 'Switch focus between tree and editor', force = true })
  vim.keymap.set('n', '<leader>e', M.toggle, { desc = 'Toggle file tree', silent = true })
  vim.keymap.set('n', '<leader>o', M.focus, { desc = 'Focus file tree / editor', silent = true })
  remember(api.nvim_get_current_win())
end
return M