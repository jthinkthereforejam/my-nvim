-- Project shell sessions displayed in the current window, without creating splits.
local M = {}
local api = vim.api
local function pack(...) return { n = select('#', ...), ... } end
local projects, sessions_by_id, sessions_by_buf, views = {}, {}, {}, {}
local next_id, internal_depth = 0, 0
local options = { toggle_key = '<C-j>' }
local window_options = { 'number', 'relativenumber', 'signcolumn', 'cursorline', 'winfixheight' }

local function guarded(callback)
  internal_depth = internal_depth + 1
  local result = pack(xpcall(callback, debug.traceback))
  internal_depth = internal_depth - 1
  if not result[1] then error(result[2], 0) end
  return unpack(result, 2, result.n)
end
local function root_info(path)
  path = vim.fs.normalize(vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ':p'))
  if path ~= '/' and not path:match('^%a:/$') then path = path:gsub('/+$', '') end
  return vim.fn.has('win32') == 1 and path:lower() or path, path
end
local function current_root()
  local session = sessions_by_buf[api.nvim_get_current_buf()]
  return session and session.root or require('config.search').project_root()
end
local function project_for(root, create)
  local key, path = root_info(root or current_root())
  if not projects[key] and create then projects[key] = { key = key, root = path, sessions = {} } end
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
local function input_mode(origin)
  local mode = origin or vim.fn.mode(1)
  return (mode == 'i' or mode:match('^i') or mode:match('^niI')) and 'i' or 'n'
end
local function capture_options(win)
  local result = {}
  for _, name in ipairs(window_options) do result[name] = api.nvim_get_option_value(name, { win = win }) end
  return result
end
local function apply_options(win, values)
  for _, name in ipairs(window_options) do
    local value = values and values[name]
    if value == nil then value = api.nvim_get_option_value(name, { scope = 'global' }) end
    api.nvim_set_option_value(name, value, { win = win })
  end
end
local function save_view(win) return api.nvim_win_call(win, vim.fn.winsaveview) end
local function restore_view(win, view)
  if view then api.nvim_win_call(win, function() vim.fn.winrestview(view) end) end
end
local function set_buffer(win, buf)
  -- A temporary switch must never write or unload unsaved editor contents,
  -- including when the caller has disabled 'hidden' or uses a wipe-on-hide page.
  local before, hidden = api.nvim_win_get_buf(win), vim.o.hidden
  local bufhidden = vim.bo[before].bufhidden
  vim.o.hidden, vim.bo[before].bufhidden = true, 'hide'
  local ok, err = pcall(api.nvim_win_set_buf, win, buf)
  vim.o.hidden = hidden
  if api.nvim_buf_is_valid(before) then vim.bo[before].bufhidden = bufhidden end
  if not ok then error(err, 0) end
end
local function attached(view)
  local session = view and sessions_by_id[view.session]
  return view and api.nvim_win_is_valid(view.win) and session
    and api.nvim_buf_is_valid(session.bufnr) and api.nvim_buf_is_loaded(session.bufnr)
    and api.nvim_win_get_buf(view.win) == session.bufnr
end
local function fallback_buffer()
  local alternate = vim.fn.bufnr('#')
  if alternate > 0 and api.nvim_buf_is_valid(alternate) and vim.bo[alternate].buftype ~= 'terminal' then return alternate end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and vim.bo[buf].buflisted then return buf end
  end
  return api.nvim_create_buf(true, false)
end
local function remember_origin(win, origin)
  local buf = api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype == 'terminal' then
    return { buf = fallback_buffer(), mode = 'n' }
  end
  return { buf = buf, mode = input_mode(origin), view = save_view(win), options = capture_options(win) }
end
local function return_buffer(view)
  local buf = view.origin.buf
  if not buf or not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype == 'terminal' then
    buf = api.nvim_create_buf(true, false)
    view.origin.buf = buf
  end
  return buf
end
local function resume_editor(view)
  local win, buf = view.win, view.origin.buf
  if view.origin.mode ~= 'i' or api.nvim_get_current_win() ~= win then return end
  local tick, cursor = api.nvim_buf_get_changedtick(buf), api.nvim_win_get_cursor(win)
  vim.schedule(function()
    if api.nvim_win_is_valid(win) and api.nvim_get_current_win() == win
      and api.nvim_win_get_buf(win) == buf and not views[win] and vim.bo[buf].buftype ~= 'terminal'
      and api.nvim_buf_get_changedtick(buf) == tick and vim.deep_equal(api.nvim_win_get_cursor(win), cursor) then
      local saved = view.origin.view
      local line = api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1] or ''
      -- Normal mode cannot retain the insertion point past the final character.
      -- :startinsert! reaches that exact end position without a delayed cursor
      -- repair that could run after the user's next keystroke.
      vim.cmd.startinsert({ bang = saved ~= nil and saved.col >= #line })
      -- :startinsert resets the desired column; preserve vertical movement too.
      if saved then vim.fn.winrestview({ curswant = saved.curswant }) end
    end
  end)
end
local function restore_origin(view, resume)
  if not view or not api.nvim_win_is_valid(view.win) then
    if view then views[view.win] = nil end
    return false
  end
  guarded(function()
    set_buffer(view.win, return_buffer(view))
    apply_options(view.win, view.origin.options)
    restore_view(view.win, view.origin.view)
  end)
  if views[view.win] == view then views[view.win] = nil end
  if resume then resume_editor(view) end
  return true
end
local function reconcile(view)
  if views[view.win] ~= view or attached(view) then return end
  if not api.nvim_win_is_valid(view.win) then views[view.win] = nil; return end
  if view.pending_delete or not api.nvim_buf_is_valid(view.bufnr) or not api.nvim_buf_is_loaded(view.bufnr) then
    restore_origin(view, api.nvim_get_current_win() == view.win)
  else
    -- The user intentionally selected another buffer. Keep that selection while
    -- removing terminal-specific window options; its next toggle gets a new origin.
    guarded(function() apply_options(view.win, view.origin.options) end)
    views[view.win] = nil
  end
end
local function current_view()
  local view = views[api.nvim_get_current_win()]
  return attached(view) and view or nil
end
local function show_session(session, origin)
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_config(win).relative ~= '' then
    error('Select an editing window before opening a terminal.')
  end
  local view = views[win]
  if view and not attached(view) then reconcile(view); view = views[win] end
  if not view then
    view = { win = win, origin = remember_origin(win, origin) }
    views[win] = view
  end
  guarded(function()
    set_buffer(win, session.bufnr)
    view.root, view.session, view.bufnr, view.pending_delete = session.root, session.id, session.bufnr, nil
    -- Leave all dimensions, split positions and winfixheight unchanged.
    for name, value in pairs({ number = false, relativenumber = false, signcolumn = 'no', cursorline = false }) do
      api.nvim_set_option_value(name, value, { win = win })
    end
  end)
  projects[session.key].selected = session.id
  if session.status == 'running' then
    api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(session.bufnr), 0 })
    vim.schedule(function()
      if views[win] == view and view.session == session.id and attached(view)
        and api.nvim_get_current_win() == win and session.status == 'running' then vim.cmd.startinsert() end
    end)
  end
  return view
end
local function forget(session)
  if sessions_by_id[session.id] ~= session then return end
  sessions_by_id[session.id], sessions_by_buf[session.bufnr] = nil, nil
  local project = projects[session.key]
  if project then
    for index, id in ipairs(project.sessions) do
      if id == session.id then table.remove(project.sessions, index); break end
    end
    if project.selected == session.id then project.selected = nil; selected(project) end
  end
end
local function shell_argv()
  local argv = vim.deepcopy(options.shell)
  -- Preserve output after successful exit, instead of the default bare-&shell cleanup.
  if table.concat(argv, ' ') == vim.o.shell then
    local name = vim.fs.basename(argv[1]):lower():gsub('%.exe$', '')
    if name == 'cmd' then argv[#argv + 1] = '/k'
    elseif name == 'powershell' or name == 'pwsh' then argv[#argv + 1] = '-NoLogo'
    elseif vim.tbl_contains({ 'sh', 'bash', 'zsh', 'dash', 'ksh', 'fish' }, name) then argv[#argv + 1] = '-i' end
  end
  return argv
end
local function create_session(root, origin)
  local project = project_for(root, true)
  local before = current_view()
  local previous = before and sessions_by_id[before.session] or nil
  next_id = next_id + 1
  local session = { id = next_id, key = project.key, root = project.root,
    bufnr = api.nvim_create_buf(false, false), status = 'running' }
  vim.bo[session.bufnr].bufhidden, vim.bo[session.bufnr].swapfile = 'hide', false
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
    local view = views[api.nvim_get_current_win()]
    if view then
      if previous and sessions_by_id[previous.id] and api.nvim_buf_is_valid(previous.bufnr) then pcall(show_session, previous, origin)
      else pcall(restore_origin, view, true) end
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
  local view = current_view()
  local project = project_for(view and view.root or current_root(), false)
  local session = view and sessions_by_id[view.session] or selected(project)
  return { win = view and view.win or nil, visible = view ~= nil,
    root = project and project.root or current_root(), active = session and session.id or nil,
    session = snapshot(session) }
end
function M.toggle(origin)
  local view = current_view()
  if view then restore_origin(view, true)
  else
    local stale = views[api.nvim_get_current_win()]
    if stale then reconcile(stale) end
    local root = current_root()
    local session = selected(project_for(root, false))
    -- A managed buffer reached through :buffer still toggles back to an editor.
    local displayed = sessions_by_buf[api.nvim_get_current_buf()]
    if displayed then
      local win = api.nvim_get_current_win()
      restore_origin({ win = win, origin = remember_origin(win, 'n') }, false)
    elseif session then show_session(session, origin)
    else create_session(root, origin) end
  end
  return M.status()
end
function M.new() return snapshot(create_session(current_root(), input_mode())) end
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
  local actions, action_state = require('telescope.actions'), require('telescope.actions.state')
  local target = api.nvim_get_current_win()
  require('telescope.pickers').new({}, {
    prompt_title = 'Terminals: ' .. vim.fs.basename(root),
    finder = require('telescope.finders').new_table({ results = entries,
      entry_maker = function(entry) return { value = entry, display = entry.label, ordinal = entry.label } end }),
    sorter = require('telescope.config').values.generic_sorter({}),
    attach_mappings = function(prompt)
      local function choose()
        local entry = action_state.get_selected_entry()
        actions.close(prompt)
        if not entry then return end
        -- Let Telescope finish leaving its prompt's Insert mode before starting
        -- terminal input in the source window.
        vim.schedule(function()
          if not api.nvim_win_is_valid(target) then return end
          api.nvim_set_current_win(target)
          if entry.value.new then create_session(root, 'n')
          else
            local session = sessions_by_id[entry.value.id]
            if session and session.key == key and api.nvim_buf_is_valid(session.bufnr) then show_session(session, 'n') end
          end
        end)
      end
      for _, action in ipairs({ 'select_default', 'select_horizontal', 'select_vertical', 'select_tab' }) do actions[action]:replace(choose) end
      return true
    end,
  }):find()
end
function M.close(id)
  local view, project = current_view(), project_for(nil, false)
  local session
  if id ~= nil then session = sessions_by_id[id]
  else session = (view and sessions_by_id[view.session]) or selected(project) end
  if not session then return false end
  local focus = api.nvim_get_current_win()
  local targets = {}
  for _, item in pairs(views) do if item.session == session.id then targets[#targets + 1] = item end end
  for _, item in ipairs(targets) do
    if attached(item) then restore_origin(item, item.win == focus) else reconcile(item) end
  end
  forget(session)
  -- Deleting a terminal buffer stops its job. A separate preceding jobstop can
  -- race native Windows PTY teardown, so only use it if deletion itself fails.
  local deleted = api.nvim_buf_is_valid(session.bufnr) and pcall(api.nvim_buf_delete, session.bufnr, { force = true })
  if not deleted and session.job and session.status == 'running' then pcall(vim.fn.jobstop, session.job) end
  return true
end
function M.with_editors(callback)
  local saved, focus = {}, api.nvim_get_current_win()
  return guarded(function()
    for _, view in pairs(views) do
      if attached(view) or (view.pending_delete and api.nvim_win_is_valid(view.win)) then
        saved[#saved + 1] = { view = view, options = capture_options(view.win), screen = save_view(view.win) }
      end
    end
    local result = pack(xpcall(function()
      for _, item in ipairs(saved) do
        local view = item.view
        set_buffer(view.win, return_buffer(view))
        apply_options(view.win, view.origin.options)
        restore_view(view.win, view.origin.view)
      end
      return callback()
    end, debug.traceback))
    local restore_error
    for _, item in ipairs(saved) do
      local view = item.view
      local session = sessions_by_id[view.session]
      if views[view.win] == view and api.nvim_win_is_valid(view.win) and session and api.nvim_buf_is_valid(session.bufnr) then
        local ok, err = pcall(function()
          set_buffer(view.win, session.bufnr)
          apply_options(view.win, item.options)
          restore_view(view.win, item.screen)
        end)
        if not ok then restore_error = restore_error or err end
      end
    end
    if api.nvim_win_is_valid(focus) then
      local ok, err = pcall(api.nvim_set_current_win, focus)
      if not ok then restore_error = restore_error or err end
    end
    if not result[1] then error(result[2], 0) end
    if restore_error then error(restore_error, 0) end
    return unpack(result, 2, result.n)
  end)
end
function M.setup(machine)
  local configured = (machine or {}).terminal or {}
  -- Older local.lua files may retain height; it is deliberately ignored now.
  options = vim.tbl_extend('force', { toggle_key = '<C-j>',
    shell = vim.fn.has('win32') == 1 and { 'powershell.exe', '-NoLogo' }
      or { vim.env.SHELL or vim.o.shell, '-l' } }, configured)
  assert(type(options.shell) == 'table' and vim.islist(options.shell) and #options.shell > 0,
    'local.lua terminal.shell must be a non-empty argv array')
  for _, argument in ipairs(options.shell) do assert(type(argument) == 'string', 'Terminal shell arguments must be strings') end
  assert(type(options.toggle_key) == 'string' and options.toggle_key ~= '', 'Terminal toggle key must be a string')
  local group = api.nvim_create_augroup('my-nvim-terminal', { clear = true })
  api.nvim_create_autocmd('WinClosed', { group = group, callback = function(args) views[tonumber(args.match)] = nil end })
  api.nvim_create_autocmd('BufWinLeave', {
    group = group, callback = function(args)
      if internal_depth > 0 then return end
      for _, view in pairs(views) do
        if view.bufnr == args.buf then
          vim.schedule(function() if internal_depth == 0 then reconcile(view) end end)
        end
      end
    end,
  })
  api.nvim_create_autocmd({ 'BufDelete', 'BufUnload', 'BufWipeout' }, {
    group = group, callback = function(args)
      local session = sessions_by_buf[args.buf]
      if not session then return end
      for _, view in pairs(views) do
        if view.session == session.id then view.pending_delete = true end
      end
      forget(session)
      vim.schedule(function()
        for _, view in pairs(views) do if view.pending_delete then reconcile(view) end end
      end)
    end,
  })
  local map = function(keys, callback, description)
    vim.keymap.set('n', keys, callback, { desc = description, silent = true })
  end
  map(options.toggle_key, function() M.toggle('n') end, 'Switch current window between editor and terminal')
  vim.keymap.set('i', options.toggle_key, [[<Cmd>lua require('config.terminal').toggle('i')<CR>]],
    { desc = 'Switch current window to terminal', silent = true })
  vim.keymap.set('t', options.toggle_key, [[<C-\><C-n><Cmd>lua require('config.terminal').toggle('t')<CR>]],
    { desc = 'Switch current window back to editor', silent = true })
  map('<leader>tt', M.toggle, 'Switch current window between editor and terminal')
  map('<leader>tn', M.new, 'New project terminal in current window')
  map('<leader>ts', M.select, 'Select project terminal in current window')
  map('<leader>tx', M.close, 'Close terminal session')
  for name, callback in pairs({ TerminalToggle = M.toggle, TerminalNew = M.new, TerminalSelect = M.select, TerminalClose = M.close }) do
    api.nvim_create_user_command(name, function() callback() end, { force = true })
  end
end
return M
