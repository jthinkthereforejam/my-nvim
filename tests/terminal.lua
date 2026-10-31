-- Run after loading this configuration:
-- nvim --headless -c "lua dofile(vim.fn.stdpath('config') .. '/tests/terminal.lua')"
-- Real shell jobs and Telescope rendering; fixtures stay in the cache.
assert(vim.g.my_nvim_ready, 'Load the my-nvim configuration before this test')
local api, fn = vim.api, vim.fn
local terminal = require('config.terminal')
local base = vim.fs.joinpath(fn.stdpath('cache'), 'my-nvim-terminal-tests', tostring(vim.uv.os_getpid()))
local roots = { vim.fs.joinpath(base, 'project-a'), vim.fs.joinpath(base, 'project-b') }
local jobs = {}
local windows = fn.has('win32') == 1
local newline = windows and '\r' or '\n'
local function quote(value)
  return windows and ("'" .. value:gsub("'", "''") .. "'") or fn.shellescape(value)
end
local function print_command(value)
  return windows and ('Write-Output ' .. quote(value)) or ("printf '%s\\n' " .. quote(value))
end

local function canonical(path)
  local value = vim.fs.normalize(vim.uv.fs_realpath(path) or path):gsub('[/\\]+$', '')
  return fn.has('win32') == 1 and value:lower() or value
end
local function same_root(left, right) return canonical(left) == canonical(right) end
local function wait_for(callback, message, timeout)
  assert(vim.wait(timeout or 10000, callback, 30), message)
end
local function remember(session)
  if session and session.job and session.job > 0 then jobs[session.job] = true end
  return session
end
local function current()
  local state = terminal.status()
  assert(state.win and api.nvim_win_is_valid(state.win), 'Terminal panel is not visible')
  local bufnr = api.nvim_win_get_buf(state.win)
  for _, session in ipairs(terminal.sessions(state.root)) do
    if session.id == state.active and session.bufnr == bufnr then return remember(session), state end
  end
  error('Visible panel is not backed by its selected session: ' .. vim.inspect(state))
end
local function output(session)
  assert(api.nvim_buf_is_valid(session.bufnr), 'Terminal buffer was unexpectedly destroyed')
  return api.nvim_buf_get_lines(session.bufnr, 0, -1, false)
end
local function expect_line(session, line, timeout)
  wait_for(function()
    for _, text in ipairs(output(session)) do if vim.trim(text) == line then return true end end
    return false
  end, 'PowerShell output did not contain a standalone line: ' .. line, timeout)
end
local function send(session, command)
  assert(fn.jobwait({ session.job }, 0)[1] == -1, 'Shell job is not running')
  if windows then
    wait_for(function()
      local text = table.concat(output(session), '\n')
      return text:find('PS ', 1, true) ~= nil and text:find('>', 1, true) ~= nil
    end, 'PowerShell did not finish starting', 30000)
  end
  assert(fn.chansend(session.job, command .. newline) > 0, 'Could not write to shell stdin')
end
local function find(root, id)
  for _, session in ipairs(terminal.sessions(root)) do if session.id == id then return session end end
end
local function project(index)
  local root = roots[index]
  fn.mkdir(vim.fs.joinpath(root, 'nested'), 'p')
  local result = vim.system({ 'git', 'init', '--quiet', root }, { text = true }):wait(10000)
  assert(result.code == 0, 'Could not create a disposable Git project: ' .. (result.stderr or ''))
  local file = vim.fs.joinpath(root, 'notes.txt')
  fn.writefile({ 'saved fixture text' }, file)
  return file
end
local function leave_terminal_mode() vim.cmd.stopinsert() end
local function editor_options(win)
  local result = {}
  for _, name in ipairs({ 'number', 'relativenumber', 'signcolumn', 'cursorline', 'winfixheight' }) do
    result[name] = api.nvim_get_option_value(name, { win = win })
  end
  return result
end
local function cleanup()
  for _, root in ipairs(roots) do
    for _, session in ipairs(terminal.sessions(root)) do remember(session) end
  end
  for job in pairs(jobs) do pcall(fn.jobstop, job) end
  local pending = {}
  for job in pairs(jobs) do pending[#pending + 1] = job end
  if #pending > 0 then pcall(fn.jobwait, pending, 5000) end
end

local function run()
  vim.o.columns, vim.o.lines = 120, 40
  local file_a, file_b = project(1), project(2)
  fn.chdir(roots[1])
  vim.cmd.edit(fn.fnameescape(file_a))
  local editor_buf, editor_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  api.nvim_buf_set_lines(editor_buf, 0, -1, false, { 'unsaved editing text' })
  local original_options = editor_options(editor_win)
  local tabs_before = #api.nvim_list_tabpages()
  local windows_before = #api.nvim_tabpage_list_wins(0)

  vim.cmd.TerminalToggle()
  local first, state = current()
  assert(same_root(first.root, roots[1]), 'First shell did not belong to the current Git project')
  assert(#api.nvim_tabpage_list_wins(0) == windows_before + 1, 'Terminal did not use one bottom split')
  assert(api.nvim_win_get_buf(editor_win) == editor_buf and vim.bo[editor_buf].modified,
    'Opening the terminal replaced or saved the editor buffer')
  assert(fn.readfile(file_a)[1] == 'saved fixture text', 'Opening the terminal wrote unsaved text to disk')

  send(first, windows and "Write-Output ('MY_NVIM_REAL_POWERSHELL=' + $PSVersionTable.PSVersion.Major)"
    or print_command('MY_NVIM_REAL_POSIX_SHELL'))
  wait_for(function()
    for _, text in ipairs(output(first)) do
      if windows and text:match('^MY_NVIM_REAL_POWERSHELL=%d+$') then return true end
      if not windows and vim.trim(text) == 'MY_NVIM_REAL_POSIX_SHELL' then return true end
    end
    return false
  end, 'The configured process did not produce the native shell marker')

  local nested = vim.fs.joinpath(roots[1], 'nested')
  send(first, (windows and ('Set-Location -LiteralPath ' .. quote(nested)) or ('cd ' .. quote(nested)))
    .. '; ' .. print_command('MY_NVIM_CD_DONE'))
  expect_line(first, 'MY_NVIM_CD_DONE')
  -- The command is sent before hiding; the delayed output must arrive while no
  -- terminal window is visible, without changing the original job.
  send(first, (windows and 'Start-Sleep -Milliseconds 350' or 'sleep 0.35')
    .. '; ' .. print_command('MY_NVIM_HIDDEN_OUTPUT'))
  leave_terminal_mode()
  terminal.toggle('n')
  assert(not terminal.status().win, 'Toggle did not hide the terminal panel')
  assert(api.nvim_get_current_buf() == editor_buf and vim.bo[editor_buf].modified, 'Hide lost the editing buffer')
  expect_line(first, 'MY_NVIM_HIDDEN_OUTPUT')
  assert(find(roots[1], first.id).job == first.job, 'Hiding the panel replaced its live process')
  terminal.toggle('n')
  local restored = current()
  assert(restored.id == first.id and restored.job == first.job and restored.bufnr == first.bufnr,
    'Reopening failed to reuse the existing terminal buffer and process')

  send(first, windows and "Write-Output ('MY_NVIM_CWD=' + (Get-Location).Path)"
    or "printf 'MY_NVIM_CWD=%s\\n' \"$PWD\"")
  wait_for(function()
    for _, line in ipairs(output(first)) do
      local cwd = line:match('^MY_NVIM_CWD=(.+)$')
      if cwd and same_root(cwd, nested) then return true end
    end
    return false
  end, 'Reopening reset the shell working directory')

  -- Switch to a different project while the shared terminal panel is open.
  api.nvim_set_current_win(editor_win)
  vim.cmd.edit(fn.fnameescape(file_b))
  local second_editor = api.nvim_get_current_buf()
  local shared_win = terminal.status().win
  terminal.toggle('n')
  assert(not terminal.status().win, 'A visible panel should hide before opening the other project')
  terminal.toggle('n')
  local other, other_state = current()
  assert(same_root(other.root, roots[2]) and other.job ~= first.job, 'Git projects shared a shell process')
  shared_win = other_state.win
  assert(#api.nvim_tabpage_list_wins(0) == windows_before + 1, 'Switching projects left multiple terminal panels')
  assert(#terminal.sessions(roots[1]) == 1 and #terminal.sessions(roots[2]) == 1, 'Project session lists leaked')
  leave_terminal_mode()
  terminal.toggle('n')
  api.nvim_set_current_win(editor_win)
  api.nvim_set_current_buf(editor_buf)
  terminal.toggle('n')
  assert(current().job == first.job, 'Returning to the first project lost its session')
  shared_win = terminal.status().win
  assert(api.nvim_buf_is_valid(second_editor), 'Switching projects destroyed an unrelated editing buffer')

  vim.cmd.TerminalNew()
  local second, second_state = current()
  assert(second.id ~= first.id and second.job ~= first.job and same_root(second.root, first.root),
    'New terminal did not create a distinct session for the current project')
  assert(second_state.win == shared_win and #terminal.sessions(roots[1]) == 2, 'New terminal did not reuse the panel')
  terminal.select(first.id)
  assert(current().id == first.id and current().job == first.job, 'Selecting an existing session restarted it')

  -- Open the installed Telescope picker and run its actual selection callback.
  -- No picker/window/session implementation is replaced by a test double.
  leave_terminal_mode()
  api.nvim_set_current_win(editor_win)
  terminal.select()
  local prompt
  wait_for(function()
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      local buf = api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == 'TelescopePrompt' then prompt = buf; return true end
    end
    return false
  end, 'TerminalSelect did not render a Telescope picker')
  local picker = require('telescope.actions.state').get_current_picker(prompt)
  wait_for(function() return picker.manager and picker.manager:num_results() >= 2 end, 'Picker did not list both project terminals')
  picker:set_selection(picker:get_row(2))
  local entry = assert(picker:get_selection(), 'Terminal picker has no selected entry')
  local selected_id = type(entry.value) == 'table' and entry.value.id or entry.value
  assert(selected_id == first.id or selected_id == second.id, 'Picker entry does not identify a project terminal')
  require('telescope.actions').select_default(prompt)
  wait_for(function() return terminal.status().active == selected_id and terminal.status().win ~= nil end,
    'Telescope selection did not display the selected terminal')
  assert(current().id == selected_id, 'Picker callback displayed the wrong session')

  terminal.select(second.id)
  send(second, print_command('MY_NVIM_EXIT_OUTPUT') .. '; exit 7')
  wait_for(function()
    local session = find(roots[1], second.id)
    return session and session.status == 'ended' and session.exit_code == 7
  end, 'Exited shell was not retained with its exit code')
  expect_line(second, 'MY_NVIM_EXIT_OUTPUT')
  assert(api.nvim_buf_is_valid(second.bufnr), 'Shell exit deleted the terminal output buffer')
  leave_terminal_mode()
  terminal.toggle('n')
  terminal.toggle('n')
  assert(current().id == second.id and current().job == second.job, 'Reopening an ended session started a new shell')

  -- Even when the terminal is the last window, hiding must keep the tab alive.
  terminal.select(first.id)
  local panel = terminal.status().win
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do if win ~= panel then api.nvim_win_close(win, true) end end
  assert(#api.nvim_tabpage_list_wins(0) == 1, 'Could not construct the single-window case')
  leave_terminal_mode()
  terminal.toggle('n')
  assert(#api.nvim_list_tabpages() == tabs_before and #api.nvim_tabpage_list_wins(0) >= 1,
    'Hiding the sole terminal window closed its tab')
  assert(not terminal.status().win and vim.bo.buftype ~= 'terminal', 'Sole-window hide did not leave an editing window')
  assert(vim.deep_equal(editor_options(api.nvim_get_current_win()), original_options),
    'Sole-window hide retained terminal-specific editor options: ' .. vim.inspect(editor_options(api.nvim_get_current_win())))
  assert(api.nvim_buf_is_valid(editor_buf) and vim.bo[editor_buf].modified, 'Single-window recovery lost unsaved edits')

  fn.chdir(roots[1])
  api.nvim_set_current_buf(editor_buf)
  terminal.select(first.id)
  local manual_win = terminal.status().win
  api.nvim_win_close(manual_win, true)
  wait_for(function() return not terminal.status().win end, 'Manual window close left a stale panel handle')
  terminal.toggle('n')
  assert(current().id == first.id and current().job == first.job, 'Manual close recovery restarted the session')
  leave_terminal_mode()
  vim.cmd('bdelete! ' .. first.bufnr)
  wait_for(function() return not find(roots[1], first.id) end, 'Deleting a terminal buffer left a stale session')
  terminal.toggle('n')
  if not terminal.status().win then terminal.toggle('n') end
  local recovered = current()
  assert(recovered.bufnr ~= first.bufnr and api.nvim_buf_is_valid(recovered.bufnr), 'Toggle after bdelete reused a deleted buffer')

  local closing_id = recovered.id
  assert(terminal.close(closing_id), 'TerminalClose did not close the selected session')
  assert(not find(roots[1], closing_id), 'TerminalClose kept a closed session in the list')
  assert(api.nvim_buf_get_lines(editor_buf, 0, -1, true)[1] == 'unsaved editing text' and vim.bo[editor_buf].modified,
    'Terminal operations changed the original unsaved editor contents')
  assert(fn.readfile(file_a)[1] == 'saved fixture text', 'Terminal operations saved the editing buffer')

  -- Sharing a project session between tabs must not leave an orphan panel or
  -- move the caller into another tab/window when that session is closed.
  fn.chdir(roots[1])
  api.nvim_set_current_buf(editor_buf)
  local first_tab = api.nvim_get_current_tabpage()
  local shared = remember(terminal.new())
  local first_tab_panel = terminal.status().win
  leave_terminal_mode()
  vim.cmd.tabnew()
  local second_tab = api.nvim_get_current_tabpage()
  api.nvim_set_current_buf(editor_buf)
  local second_tab_editor = api.nvim_get_current_win()
  terminal.select(shared.id)
  assert(current().job == shared.job, 'A second tab started a separate job for the same selected session')
  api.nvim_set_current_win(second_tab_editor)
  assert(terminal.close(shared.id), 'Could not close the session shared across tabs')
  wait_for(function() return fn.jobwait({ shared.job }, 0)[1] ~= -1 end, 'Closing the shared session left its shell running')
  assert(api.nvim_get_current_tabpage() == second_tab and api.nvim_get_current_win() == second_tab_editor,
    'Closing a shared session changed the caller tab or editor focus')
  assert(not terminal.status().win, 'Closing a shared session left an orphan panel in the caller tab')
  api.nvim_set_current_tabpage(first_tab)
  assert(not terminal.status().win, 'Closing a shared session left an orphan panel in the other tab')
  if api.nvim_win_is_valid(first_tab_panel) then
    assert(vim.bo[api.nvim_win_get_buf(first_tab_panel)].buftype ~= 'terminal', 'The other tab still shows a dead terminal buffer')
  end
  api.nvim_set_current_tabpage(second_tab)
  api.nvim_set_current_win(second_tab_editor)
  print('PASS terminal: real shell, hide/reopen same job, background output, shell cwd, unsaved edits, project isolation, multiple sessions, real Telescope selection, exit retention, sole-window hide/options, close/bdelete recovery, cross-tab close/focus')
end

vim.schedule(function()
  local ok, err = xpcall(run, debug.traceback)
  cleanup()
  if not ok then api.nvim_err_writeln(err); vim.cmd('cquit 1') else vim.cmd('qa!') end
end)
