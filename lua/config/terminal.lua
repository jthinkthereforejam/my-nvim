-- A project terminal panel built on Neovim's own buffers, windows and jobs.
local M = {}
local api = vim.api
local projects, sessions_by_id, sessions_by_buf, panels = {}, {}, {}, {}
local next_id = 0
local options = { height = 0.33, toggle_key = '<C-j>' }
local panel_options = { 'number', 'relativenumber', 'signcolumn', 'cursorline', 'winfixheight' }

local function root_info(path)
  path = vim.fs.normalize(vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ':p'))
  if path ~= '/' and not path:match('^%a:/$') then path = path:gsub('/+$', '') end
  return vim.fn.has('win32') == 1 and path:lower() or path, path
end

local function current_root()
  local session = sessions_by_buf[api.nvim_get_current_buf()]
  if session then return session.root end
  return require('config.search').project_root()
end

local function project_for(root, create)
  local key, path = root_info(root or current_root())
  if not projects[key] and create then
    projects[key] = { key = key, root = path, sessions = {} }
  end
  return projects[key], key, path
end

local function snapshot(session)
  if not session then return nil end
  return { id = session.id, root = session.root, bufnr = session.bufnr, job = session.job,
    status = session.status, exit_code = session.exit_code }
end

local function selected(project)
  if not project then return nil end
  local session = sessions_by_id[project.selected]
  if session and api.nvim_buf_is_valid(session.bufnr) and api.nvim_buf_is_loaded(session.bufnr) then return session end
  for index = #project.sessions, 1, -1 do
    session = sessions_by_id[project.sessions[index]]
    if session and api.nvim_buf_is_valid(session.bufnr) and api.nvim_buf_is_loaded(session.bufnr) then
      project.selected = session.id
      return session
    end
  end
  project.selected = nil
end

local function panel_for(tab, create)
  tab = tab or api.nvim_get_current_tabpage()
  local panel = panels[tab]
  if not panel and create then
    panel = { tab = tab }
    panels[tab] = panel
  end
  if panel and panel.win then
    local session = sessions_by_id[panel.session]
    if not api.nvim_win_is_valid(panel.win) or api.nvim_win_get_tabpage(panel.win) ~= tab
      or (session and api.nvim_win_get_buf(panel.win) ~= session.bufnr)
      or (not session and panel.pending_delete ~= panel.session) then
      panel.win, panel.session, panel.pending_delete = nil, nil, nil
    end
  end
  return panel
end

local function input_mode(origin)
  local mode = origin or vim.fn.mode(1)
  return (mode == 'i' or mode:match('^i') or mode:match('^niI')) and 'i' or 'n'
end

local function editor_window(win, tab)
  return win and api.nvim_win_is_valid(win) and api.nvim_win_get_tabpage(win) == tab
    and api.nvim_win_get_config(win).relative == ''
    and vim.bo[api.nvim_win_get_buf(win)].buftype ~= 'terminal'
end

local function remember_origin(panel, origin)
  local win = api.nvim_get_current_win()
  if win ~= panel.win and editor_window(win, panel.tab) then
    panel.return_win, panel.return_buf = win, api.nvim_win_get_buf(win)
    panel.return_mode = input_mode(origin)
    panel.return_options = {}
    for _, name in ipairs(panel_options) do
      panel.return_options[name] = api.nvim_get_option_value(name, { win = win })
    end
  end
end

local function resume_editor(win, mode)
  if not win or not api.nvim_win_is_valid(win) then return end
  api.nvim_set_current_win(win)
  if mode == 'i' then
    vim.schedule(function()
      if api.nvim_win_is_valid(win) and api.nvim_get_current_win() == win
        and vim.bo[api.nvim_win_get_buf(win)].buftype ~= 'terminal' then
        vim.cmd.startinsert()
      end
    end)
  end
end

local function panel_height(panel)
  local maximum = math.max(1, vim.o.lines - vim.o.cmdheight - 3)
  return math.max(1, math.min(panel.height or math.floor(vim.o.lines * options.height), maximum))
end

local function hide_panel(panel, origin, restore_focus)
  if not panel or not panel.win then return false end
  local win = panel.win
  remember_origin(panel, origin)
  panel.height = api.nvim_win_get_height(win)
  local return_mode = panel.return_mode
  local target = editor_window(panel.return_win, panel.tab) and panel.return_win or nil
  local ordinary = 0
  for _, candidate in ipairs(api.nvim_tabpage_list_wins(panel.tab)) do
    if api.nvim_win_get_config(candidate).relative == '' then ordinary = ordinary + 1 end
    if not target and candidate ~= win and editor_window(candidate, panel.tab) then target = candidate end
  end
  if ordinary <= 1 then
    -- Hiding the last split would close its tab or fail with E444.
    local buffer = panel.return_buf
    if not buffer or not api.nvim_buf_is_valid(buffer) or vim.bo[buffer].buftype == 'terminal' then
      buffer = api.nvim_create_buf(true, false)
    end
    api.nvim_win_set_buf(win, buffer)
    for _, name in ipairs(panel_options) do
      local value = panel.return_options and panel.return_options[name]
      if value == nil then value = api.nvim_get_option_value(name, { scope = 'global' }) end
      api.nvim_set_option_value(name, value, { win = win })
    end
    target = win
  else
    api.nvim_win_hide(win)
  end
  panel.win, panel.session, panel.pending_delete = nil, nil, nil
  if restore_focus ~= false then resume_editor(target, return_mode) end
  return true
end

local function show_session(session, origin)
  local panel = panel_for(nil, true)
  remember_origin(panel, origin)
  if panel.win then
    api.nvim_set_current_win(panel.win)
    api.nvim_win_set_buf(panel.win, session.bufnr)
  else
    panel.win = api.nvim_open_win(session.bufnr, true,
      { split = 'below', win = -1, height = panel_height(panel) })
  end
  panel.root, panel.session, panel.pending_delete = session.root, session.id, nil
  projects[session.key].selected = session.id
  for name, value in pairs({ number = false, relativenumber = false,
    signcolumn = 'no', cursorline = false, winfixheight = true }) do
    api.nvim_set_option_value(name, value, { win = panel.win })
  end
  if session.status == 'running' then
    api.nvim_win_set_cursor(panel.win, { api.nvim_buf_line_count(session.bufnr), 0 })
    local win = panel.win
    vim.schedule(function()
      if api.nvim_win_is_valid(win) and api.nvim_get_current_win() == win
        and api.nvim_win_get_buf(win) == session.bufnr and session.status == 'running' then
        vim.cmd.startinsert()
      end
    end)
  end
  return panel
end

local function forget(session, keep_panels)
  if sessions_by_id[session.id] ~= session then return end
  sessions_by_id[session.id], sessions_by_buf[session.bufnr] = nil, nil
  local project = projects[session.key]
  if project then
    for index, id in ipairs(project.sessions) do
      if id == session.id then table.remove(project.sessions, index); break end
    end
    if project.selected == session.id then project.selected = nil; selected(project) end
  end
  if not keep_panels then
    for _, panel in pairs(panels) do
      if panel.session == session.id then panel.win, panel.session = nil, nil end
    end
  end
end

local function shell_argv()
  local argv = vim.deepcopy(options.shell)
  -- The built-in TermClose autocmd deletes successful bare &shell jobs.
  -- Explicit interactive flags preserve this panel's exited output without
  -- changing Neovim's handling of ordinary :terminal buffers.
  if table.concat(argv, ' ') == vim.o.shell then
    local name = vim.fs.basename(argv[1]):lower():gsub('%.exe$', '')
    if name == 'cmd' then
      argv[#argv + 1] = '/k'
    elseif name == 'powershell' or name == 'pwsh' then
      argv[#argv + 1] = '-NoLogo'
    elseif vim.tbl_contains({ 'sh', 'bash', 'zsh', 'dash', 'ksh', 'fish' }, name) then
      argv[#argv + 1] = '-i'
    end
  end
  return argv
end

local function create_session(root, origin)
  local project = project_for(root, true)
  local panel = panel_for(nil, true)
  local previous = sessions_by_id[panel.session]
  next_id = next_id + 1
  local session = { id = next_id, key = project.key, root = project.root,
    bufnr = api.nvim_create_buf(false, false), status = 'running' }
  vim.bo[session.bufnr].bufhidden = 'hide'
  vim.bo[session.bufnr].swapfile = false
  sessions_by_id[session.id], sessions_by_buf[session.bufnr] = session, session
  project.sessions[#project.sessions + 1] = session.id
  local ok, err = pcall(function()
    show_session(session, origin)
    local job = vim.fn.jobstart(shell_argv(), {
      term = true, cwd = session.root,
      on_exit = function(id, code)
        if sessions_by_id[session.id] == session and (session.job == nil or session.job == id) then
          session.status, session.exit_code = 'ended', code
        end
      end,
    })
    if job <= 0 then error('Cannot start terminal shell: ' .. tostring(options.shell[1])) end
    session.job = job
  end)
  if not ok then
    if panel.win and api.nvim_win_is_valid(panel.win) then
      if previous and sessions_by_id[previous.id] and api.nvim_buf_is_valid(previous.bufnr) then
        pcall(show_session, previous, origin)
      else
        pcall(hide_panel, panel, origin)
      end
    end
    forget(session)
    if api.nvim_buf_is_valid(session.bufnr) then pcall(api.nvim_buf_delete, session.bufnr, { force = true }) end
    vim.notify('Terminal: ' .. tostring(err), vim.log.levels.ERROR)
    return nil
  end
  return session
end

function M.sessions(root)
  local project = project_for(root, false)
  local result = {}
  if project then
    for _, id in ipairs(project.sessions) do
      local session = sessions_by_id[id]
      if session and api.nvim_buf_is_valid(session.bufnr) and api.nvim_buf_is_loaded(session.bufnr) then result[#result + 1] = snapshot(session) end
    end
  end
  return result
end

function M.status()
  local panel = panel_for()
  local project = project_for(panel and panel.win and panel.root or current_root(), false)
  local session = panel and panel.win and sessions_by_id[panel.session] or selected(project)
  return { win = panel and panel.win or nil, visible = panel ~= nil and panel.win ~= nil,
    root = project and project.root or current_root(), active = session and session.id or nil,
    session = snapshot(session) }
end

function M.toggle(origin)
  local panel = panel_for()
  if panel and panel.win then
    hide_panel(panel, origin)
  else
    local root = current_root()
    local project = project_for(root, false)
    local session = selected(project)
    if session then show_session(session, origin) else create_session(root, origin) end
  end
  return M.status()
end

function M.new()
  return snapshot(create_session(current_root(), input_mode()))
end

function M.select(id)
  local root = current_root()
  local project, key = project_for(root, false)
  if id ~= nil then
    local session = sessions_by_id[id]
    if not session or session.key ~= key then
      vim.notify('Terminal session is not in the current project.', vim.log.levels.WARN)
      return nil
    end
    show_session(session, input_mode())
    return snapshot(session)
  end
  local entries = M.sessions(root)
  for _, entry in ipairs(entries) do
    entry.label = ('%s #%d [%s%s]'):format(project and project.selected == entry.id and '*' or ' ',
      entry.id, entry.status, entry.exit_code ~= nil and (' ' .. entry.exit_code) or '')
  end
  entries[#entries + 1] = { new = true, label = '+ New terminal' }
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  require('telescope.pickers').new({}, {
    prompt_title = 'Terminals: ' .. vim.fs.basename(root),
    finder = require('telescope.finders').new_table({
      results = entries,
      entry_maker = function(entry)
        return { value = entry, display = entry.label, ordinal = entry.label }
      end,
    }),
    sorter = require('telescope.config').values.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then return end
        if entry.value.new then
          create_session(root, 'n')
        else
          local session = sessions_by_id[entry.value.id]
          if session and session.key == key and api.nvim_buf_is_valid(session.bufnr) then
            show_session(session, 'n')
          end
        end
      end)
      return true
    end,
  }):find()
end

function M.close(id)
  local panel = panel_for()
  local project = project_for(nil, false)
  local session
  if id ~= nil then
    session = sessions_by_id[id]
  else
    session = (panel and panel.win and sessions_by_id[panel.session]) or selected(project)
  end
  if not session then return false end
  local tab = api.nvim_get_current_tabpage()
  for _, view in pairs(panels) do
    if view.session == session.id and view.win and api.nvim_win_is_valid(view.win)
      and api.nvim_win_get_buf(view.win) == session.bufnr then
      hide_panel(view, nil, view.tab == tab)
    end
  end
  forget(session)
  -- Force-deleting a terminal buffer already stops its job. Stopping the same
  -- Windows PTY separately before deletion can race its native teardown.
  local deleted = api.nvim_buf_is_valid(session.bufnr)
    and pcall(api.nvim_buf_delete, session.bufnr, { force = true })
  if not deleted and session.job and session.status == 'running' then pcall(vim.fn.jobstop, session.job) end
  return true
end

function M.setup(machine)
  local configured = (machine or {}).terminal or {}
  options = vim.tbl_extend('force', { height = 0.33, toggle_key = '<C-j>',
    shell = vim.fn.has('win32') == 1 and { 'powershell.exe', '-NoLogo' }
      or { vim.env.SHELL or vim.o.shell, '-l' } }, configured)
  assert(type(options.height) == 'number' and options.height > 0 and options.height < 1,
    'local.lua terminal.height must be a fraction between 0 and 1')
  assert(type(options.shell) == 'table' and vim.islist(options.shell) and #options.shell > 0,
    'local.lua terminal.shell must be a non-empty argv array')
  for _, argument in ipairs(options.shell) do assert(type(argument) == 'string', 'Terminal shell arguments must be strings') end
  assert(type(options.toggle_key) == 'string' and options.toggle_key ~= '', 'Terminal toggle key must be a string')
  local group = api.nvim_create_augroup('my-nvim-terminal', { clear = true })
  api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
      local win = tonumber(args.match)
      for _, panel in pairs(panels) do
        if panel.win == win then panel.win, panel.session = nil, nil end
      end
    end,
  })
  api.nvim_create_autocmd({ 'BufDelete', 'BufUnload', 'BufWipeout' }, {
    group = group,
    callback = function(args)
      local session = sessions_by_buf[args.buf]
      if not session then return end
      local views = {}
      for _, view in pairs(panels) do
        if view.session == session.id and view.win then
          view.pending_delete = session.id
          views[#views + 1] = { panel = view, win = view.win }
        end
      end
      forget(session, true)
      -- Buffer-delete events can run under textlock and Neovim may already
      -- have replaced the deleted terminal with another buffer in its window.
      vim.schedule(function()
        local tab = api.nvim_get_current_tabpage()
        for _, saved in ipairs(views) do
          local view = saved.panel
          if view.win == saved.win and view.session == session.id and api.nvim_win_is_valid(saved.win) then
            pcall(hide_panel, view, nil, view.tab == tab)
          end
        end
      end)
    end,
  })
  api.nvim_create_autocmd('TabClosed', {
    group = group,
    callback = function()
      for tab in pairs(panels) do if not api.nvim_tabpage_is_valid(tab) then panels[tab] = nil end end
    end,
  })
  local map = function(keys, callback, description)
    vim.keymap.set('n', keys, callback, { desc = description, silent = true })
  end
  map(options.toggle_key, function() M.toggle('n') end, 'Toggle terminal panel')
  vim.keymap.set('i', options.toggle_key,
    [[<C-\><C-n><Cmd>lua require('config.terminal').toggle('i')<CR>]],
    { desc = 'Toggle terminal panel', silent = true })
  vim.keymap.set('t', options.toggle_key,
    [[<C-\><C-n><Cmd>lua require('config.terminal').toggle('t')<CR>]],
    { desc = 'Toggle terminal panel', silent = true })
  map('<leader>tt', M.toggle, 'Toggle terminal panel')
  map('<leader>tn', M.new, 'New project terminal')
  map('<leader>ts', M.select, 'Select project terminal')
  map('<leader>tx', M.close, 'Close terminal session')
  for name, callback in pairs({ TerminalToggle = M.toggle, TerminalNew = M.new,
    TerminalSelect = M.select, TerminalClose = M.close }) do
    api.nvim_create_user_command(name, function() callback() end, { force = true })
  end
end

return M
