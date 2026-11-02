-- A small, owned HEAD comparison. The right side is always the live buffer.
local M = {}
local api = vim.api
local states, internal = {}, 0
local scrollopt_before
local window_options = { 'diff', 'scrollbind', 'cursorbind', 'wrap',
  'foldmethod', 'foldcolumn', 'foldenable', 'foldlevel' }
local function pack(...) return { n = select('#', ...), ... } end
local function guarded(callback)
  internal = internal + 1
  local result = pack(xpcall(callback, debug.traceback))
  internal = internal - 1
  if not result[1] then error(result[2], 0) end
  return unpack(result, 2, result.n)
end
local function options(win)
  local values = {}
  for _, name in ipairs(window_options) do values[name] = api.nvim_get_option_value(name, { win = win }) end
  return values
end
local function apply_options(win, values)
  -- Disable diff before restoring its related options: :diffoff alone resets
  -- several of them to defaults instead of the user's previous values.
  api.nvim_set_option_value('diff', false, { win = win })
  for _, name in ipairs(window_options) do
    if name ~= 'diff' then api.nvim_set_option_value(name, values[name], { win = win }) end
  end
  api.nvim_set_option_value('diff', values.diff, { win = win })
end
local function view(win) return api.nvim_win_call(win, vim.fn.winsaveview) end
local function restore_view(win, saved) api.nvim_win_call(win, function() vim.fn.winrestview(saved) end) end
local function normal_windows(tab)
  local wins = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if api.nvim_win_get_config(win).relative == '' then wins[#wins + 1] = win end
  end
  return wins
end
local function restore_layout(state)
  if api.nvim_tabpage_is_valid(state.tab) and vim.deep_equal(normal_windows(state.tab), state.windows)
    and api.nvim_win_is_valid(state.right) then
    api.nvim_win_call(state.right, function() vim.cmd(state.layout) end)
  end
end
local function current_state() return states[api.nvim_get_current_tabpage()] end
local function attached(state)
  return state and not state.departed and api.nvim_win_is_valid(state.right) and api.nvim_win_is_valid(state.left)
    and api.nvim_buf_is_valid(state.snapshot) and api.nvim_win_get_buf(state.right) == state.buf
    and api.nvim_win_get_buf(state.left) == state.snapshot
    and api.nvim_buf_get_name(state.buf) == state.name
end
local function close(state)
  if not state then return false end
  states[state.tab] = nil
  guarded(function()
    local focus = api.nvim_get_current_win()
    -- If the user closed the code side and left our snapshot as the sole
    -- normal window, turn that surviving window back into an editor first.
    if not api.nvim_win_is_valid(state.right) and state.left and api.nvim_win_is_valid(state.left)
      and api.nvim_win_get_buf(state.left) == state.snapshot and #normal_windows(state.tab) == 1 then
      local editor = api.nvim_buf_is_valid(state.buf) and state.buf or api.nvim_create_buf(true, false)
      api.nvim_win_set_buf(state.left, editor)
      state.right, state.left = state.left, nil
    end
    if api.nvim_win_is_valid(state.right) then
      apply_options(state.right, state.options)
    end
    if state.left and api.nvim_win_is_valid(state.left)
      and api.nvim_win_get_buf(state.left) == state.snapshot then
      -- This is an unmodified scratch buffer, never an editor or shell job.
      api.nvim_win_close(state.left, true)
    end
    if state.snapshot and api.nvim_buf_is_valid(state.snapshot) then
      api.nvim_buf_delete(state.snapshot, { force = true })
    end
    restore_layout(state)
    if not next(states) and scrollopt_before then
      local another_diff = false
      for _, win in ipairs(api.nvim_list_wins()) do if vim.wo[win].diff then another_diff = true; break end end
      if not another_diff then vim.o.scrollopt = scrollopt_before end
      scrollopt_before = nil
    end
    if api.nvim_win_is_valid(state.right) and api.nvim_win_get_buf(state.right) == state.buf then
      restore_view(state.right, state.view)
    end
    if api.nvim_win_is_valid(focus) then api.nvim_set_current_win(focus)
    elseif api.nvim_win_is_valid(state.right) then api.nvim_set_current_win(state.right) end
  end)
  return false
end
local function notify(message)
  vim.notify(message, vim.log.levels.INFO, { title = 'Git diff' })
end
local function git(argv, cwd)
  local command = { 'git', '-C', cwd }
  vim.list_extend(command, argv)
  local ok, result = pcall(function() return vim.system(command, { text = true }):wait(3000) end)
  if not ok or result.code == 124 then return nil, 'Git did not finish; no comparison was opened.' end
  return result
end
local function head_lines(path)
  if vim.fn.executable('git') ~= 1 then return nil, 'Git is unavailable.' end
  local directory = vim.fs.dirname(path)
  local repo, err = git({ 'rev-parse', '--show-toplevel' }, directory)
  if not repo then return nil, err end
  if repo.code ~= 0 then return nil, 'This file is outside a Git repository.' end
  local root = vim.fs.normalize(vim.trim(repo.stdout or ''))
  local target = vim.fs.normalize(path)
  if vim.fn.has('win32') == 1 then
    -- Git's tree paths are case-sensitive even on a Windows working tree.
    -- Canonical casing also handles files opened through a drive/junction alias.
    root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
    target = vim.fs.normalize(vim.uv.fs_realpath(path)
      or vim.fs.joinpath(vim.uv.fs_realpath(directory) or directory, vim.fs.basename(path)))
  end
  local relative = vim.fs.relpath(root, target)
  if not relative or relative == '.' or relative:match('^%.%./') then return nil, 'This file is outside the Git working tree.' end
  relative = relative:gsub('\\', '/')
  local head
  head, err = git({ 'rev-parse', '--verify', '--quiet', 'HEAD' }, root)
  if not head then return nil, err end
  if head.code ~= 0 then
    -- An unborn branch has no previous version: all buffer lines are additions.
    if head.code == 1 then return { '' } end
    return nil, 'Could not read the Git HEAD revision.'
  end
  local revision = vim.trim(head.stdout)
  local entry
  entry, err = git({ '--literal-pathspecs', 'ls-tree', '-z', revision, '--', relative }, root)
  if not entry then return nil, err end
  if entry.code ~= 0 then return nil, 'Could not read this file from Git HEAD.' end
  if entry.stdout == '' then return { '' } end
  if not entry.stdout:match('^%d+ blob ') then return nil, 'Git HEAD does not contain a regular file at this path.' end
  local content
  content, err = git({ 'show', revision .. ':' .. relative }, root)
  if not content then return nil, err end
  if content.code ~= 0 then return nil, 'Could not read this file from Git HEAD.' end
  local text = content.stdout or ''
  -- Neovim stores a UTF-8 BOM as buffer metadata, not first-line text.
  if text:sub(1, 3) == string.char(239, 187, 191) then text = text:sub(4) end
  if text:find('\0', 1, true) then return nil, 'Binary Git files cannot be shown in this comparison.' end
  local lines = vim.split(text, '\n', { plain = true })
  if #lines > 1 and lines[#lines] == '' then table.remove(lines) end
  return lines
end
function M.status()
  local state = current_state()
  if not state then return { visible = false } end
  return { visible = attached(state), left_win = state.left, right_win = state.right,
    buf = state.buf, snapshot = state.snapshot }
end
function M.toggle()
  local old = current_state()
  if old then return close(old) end
  local right, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local name = api.nvim_buf_get_name(buf)
  if api.nvim_win_get_config(right).relative ~= '' or vim.bo[buf].buftype ~= '' or name == ''
    or vim.fn.isdirectory(name) == 1 then
    notify('Open a project file in an editing window before comparing with HEAD.'); return false
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if vim.wo[win].diff then notify('Close the existing diff before opening a HEAD comparison.'); return false end
  end
  local lines, err = head_lines(name)
  if not lines then notify(err); return false end
  local state = { tab = api.nvim_get_current_tabpage(), right = right, buf = buf, name = name,
    options = options(right), view = view(right), windows = normal_windows(api.nvim_get_current_tabpage()),
    layout = vim.fn.winrestcmd() }
  local ok, why = pcall(function()
    guarded(function()
      state.snapshot = api.nvim_create_buf(false, true)
      api.nvim_buf_set_name(state.snapshot, ('my-nvim-head://%d/%d/%s'):format(state.tab, buf, vim.fs.basename(name)))
      vim.bo[state.snapshot].buftype = 'nofile'
      vim.bo[state.snapshot].bufhidden = 'wipe'
      vim.bo[state.snapshot].swapfile = false
      vim.bo[state.snapshot].filetype = vim.bo[buf].filetype
      vim.b[state.snapshot].my_nvim_git_diff = true
      api.nvim_buf_set_lines(state.snapshot, 0, -1, false, lines)
      vim.bo[state.snapshot].modified = false
      vim.bo[state.snapshot].readonly = true
      vim.bo[state.snapshot].modifiable = false
      local equalalways = vim.o.equalalways
      vim.o.equalalways = false
      local opened, value = pcall(api.nvim_open_win, state.snapshot, false,
        { split = 'left', win = right, width = math.max(1, math.floor((api.nvim_win_get_width(right) - 1) / 2)) })
      vim.o.equalalways = equalalways
      if not opened then error(value, 0) end
      state.left = value
      if not next(states) then scrollopt_before = vim.o.scrollopt end
      states[state.tab] = state
      api.nvim_win_call(state.left, function() vim.cmd.diffthis() end)
      api.nvim_win_call(right, function() vim.cmd.diffthis() end)
      api.nvim_set_current_win(right)
    end)
  end)
  if not ok then pcall(close, state); notify('Could not open the HEAD comparison: ' .. tostring(why)); return false end
  return true
end
function M.close()
  local state = current_state()
  if not state then return false end
  close(state)
  return true
end
function M.with_editors(callback)
  local saved, focus = {}, api.nvim_get_current_win()
  local saved_scrollopt = vim.o.scrollopt
  return guarded(function()
    local result = pack(xpcall(function()
      for _, state in pairs(states) do
        if attached(state) then
          local item = { state = state, options = options(state.right), view = view(state.right),
            left_options = options(state.left), left_view = view(state.left), width = api.nvim_win_get_width(state.left),
            layout = api.nvim_win_call(state.right, vim.fn.winrestcmd) }
          saved[#saved + 1] = item
          -- Moving the same window to a hidden float removes only our ephemeral
          -- split from :mksession, while keeping its id/buffer and all jobs alive.
          api.nvim_win_set_config(state.left, { relative = 'editor', row = 0, col = 0,
            width = 1, height = 1, hide = true, focusable = false })
          apply_options(state.right, state.options)
          restore_view(state.right, state.view)
        end
      end
      if scrollopt_before then vim.o.scrollopt = scrollopt_before end
      local editor_focus = focus
      for _, item in ipairs(saved) do if item.state.left == focus then editor_focus = item.state.right; break end end
      if api.nvim_win_is_valid(editor_focus) then api.nvim_set_current_win(editor_focus) end
      return callback()
    end, debug.traceback))
    local restore_error
    for index = #saved, 1, -1 do
      local item, state = saved[index], saved[index].state
      if states[state.tab] == state and api.nvim_win_is_valid(state.left) and api.nvim_win_is_valid(state.right) then
        local ok, err = pcall(function()
          api.nvim_win_set_config(state.left, { split = 'left', win = state.right, width = item.width,
            hide = false, focusable = true })
          apply_options(state.left, item.left_options)
          apply_options(state.right, item.options)
          api.nvim_win_call(state.right, function() vim.cmd(item.layout) end)
          restore_view(state.left, item.left_view)
          restore_view(state.right, item.view)
        end)
        if not ok then restore_error = restore_error or err end
      end
    end
    vim.o.scrollopt = saved_scrollopt
    if api.nvim_win_is_valid(focus) then pcall(api.nvim_set_current_win, focus) end
    if not result[1] then error(result[2], 0) end
    if restore_error then error(restore_error, 0) end
    return unpack(result, 2, result.n)
  end)
end
function M.setup()
  local group = api.nvim_create_augroup('my-nvim-git-diff', { clear = true })
  api.nvim_create_autocmd({ 'WinClosed', 'BufLeave', 'BufWinEnter', 'BufWinLeave', 'BufFilePost', 'BufDelete', 'BufWipeout' }, {
    group = group,
    callback = function(event)
      if internal > 0 then return end
      if event.event == 'BufLeave' or event.event == 'BufWinLeave' then
        -- Native window/buffer option caching happens before BufWinLeave.
        -- Restore on BufLeave; if this was only a focus change, reapply the
        -- live diff view below once the event sequence has completed.
        for _, state in pairs(states) do
          if event.buf == state.buf and api.nvim_get_current_win() == state.right
            and api.nvim_win_is_valid(state.right) and api.nvim_win_get_buf(state.right) == state.buf then
            if event.event == 'BufWinLeave' then state.departed = true end
            if not state.leaving then state.leaving = { options = options(state.right), view = view(state.right) } end
            guarded(function()
              apply_options(state.right, state.options)
              restore_view(state.right, state.view)
            end)
          end
        end
      end
      vim.schedule(function()
        if internal > 0 then return end
        local stale = {}
        for _, state in pairs(states) do
          if not attached(state) then
            stale[#stale + 1] = state
          elseif state.leaving then
            local leaving = state.leaving
            state.leaving = nil
            guarded(function()
              apply_options(state.right, leaving.options)
              restore_view(state.right, leaving.view)
            end)
          end
        end
        for _, state in ipairs(stale) do if states[state.tab] == state then close(state) end end
      end)
    end,
  })
end
return M
