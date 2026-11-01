-- nvim --headless -c "lua dofile(vim.fn.stdpath('config') .. '/tests/projects.lua')"
-- Real independent Neovim processes, per-project MRU files and persistence sessions.
-- All source files, history and sessions created here stay below stdpath('cache').
assert(vim.g.my_nvim_ready, 'Load the my-nvim configuration before this test')
-- This suite exercises explicit saves and preservation of unsaved buffers.
require('config.autosave').setup({ autosave = { enabled = false } })
local api, fn = vim.api, vim.fn
local stage = vim.env.MY_NVIM_PROJECT_TEST_STAGE
local base = vim.env.MY_NVIM_PROJECT_TEST_BASE
  or vim.fs.joinpath(fn.stdpath('cache'), 'my-nvim-project-tests', tostring(vim.uv.os_getpid()))
local state_dir = vim.fs.joinpath(base, 'state')
local config_root = assert(vim.g.my_nvim_root)
local script = vim.fs.joinpath(config_root, 'tests/projects.lua')
local owned_jobs, owned_terminals, children = {}, {}, {}
local original_launch, original_folder, original_file
local function normalize(path)
  path = vim.fs.normalize(vim.uv.fs_realpath(path) or fn.fnamemodify(path, ':p')):gsub('[/\\]+$', '')
  return fn.has('win32') == 1 and path:lower() or path
end
local function same(left, right) return normalize(left) == normalize(right) end
local function wait_for(callback, message, timeout) assert(vim.wait(timeout or 15000, callback, 25), message) end
local function directory(name) local value = vim.fs.joinpath(base, name); fn.mkdir(value, 'p'); return value end
local function fixtures()
  return {
    empty = directory('empty-folder'), weird = directory("项目 空格 &';$目录"),
    parent = directory('parent-project'), target = directory("新窗口 &';$项目"),
    session = directory('session-project'), concurrent_a = directory('concurrent-a'), concurrent_b = directory('concurrent-b'),
  }
end
local function history_item(project, root)
  for _, entry in ipairs(project.history()) do if same(entry.root, root) then return entry end end
end
local function cleanup()
  -- Exercise VimLeavePre while every code window is still covered by its live
  -- terminal. Neovim owns PTY teardown on :qa; do not pre-stop these jobs.
  if stage == 'session-save' then return end
  if original_launch then
    local native = require('config.project_native')
    native.launch, native.choose_folder, native.choose_file = original_launch, original_folder, original_file
  end
  local jobs = {}; for job in pairs(owned_jobs) do jobs[#jobs + 1] = job end
  -- Let the native terminal-buffer owner stop its process. On Windows,
  -- jobstop followed by the buffer destruction in :qa can double-close a PTY.
  for _, session in ipairs(owned_terminals) do
    local ok, closed = pcall(require('config.terminal').close, session.id)
    if ok and closed then owned_jobs[session.job] = nil
    elseif api.nvim_buf_is_valid(session.bufnr) then
      local deleted = pcall(api.nvim_buf_delete, session.bufnr, { force = true })
      if deleted then owned_jobs[session.job] = nil end
    end
  end
  for job in pairs(owned_jobs) do pcall(fn.jobstop, job) end
  if #jobs > 0 then pcall(fn.jobwait, jobs, 5000) end
  for _, child in ipairs(children) do pcall(child.kill, child, 15); pcall(child.wait, child, 5000) end
end
local function terminal_session()
  local terminal = require('config.terminal')
  -- This test checks project-launch isolation, not the user's default shell.
  -- Hold a real process without relying on stdin/console availability in a
  -- headless child. Default-shell interaction is covered by terminal.lua.
  local command = fn.has('win32') == 1
    and { 'powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '[System.Threading.Thread]::Sleep(120000)' }
    or { '/bin/sleep', '120' }
  terminal.setup({ terminal = { shell = command } })
  local session = assert(terminal.new(), 'Could not create a real terminal fixture')
  owned_jobs[session.job] = true
  owned_terminals[#owned_terminals + 1] = session
  assert(fn.jobwait({ session.job }, 0)[1] == -1, 'Terminal fixture did not stay running')
  return session
end
local function windows()
  local result = {}
  for _, win in ipairs(api.nvim_list_wins()) do result[#result + 1] = { win, api.nvim_win_get_buf(win) } end
  table.sort(result, function(left, right) return left[1] < right[1] end)
  return result
end
local function clients(bufnr)
  local result = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do result[#result + 1] = { client.id, client.name, client:is_stopped() } end
  table.sort(result, function(left, right) return left[1] < right[1] end)
  return result
end
local function simple(root)
  local project = require('config.project')
  project.activate(root, { restore = false, pick = false })
  assert(project.root() and same(project.root(), root) and same(fn.getcwd(), root), 'A non-Git/empty project did not bind its explicit root')
  local entry = assert(history_item(project, root), 'Opening the project did not create its MRU record')
  assert(entry.exists == true and entry.name == vim.fs.basename(root) and type(entry.last_opened) == 'number', 'MRU metadata is incomplete')
  require('config.project_history').record(root .. '/')
  local count = 0
  for _, item in ipairs(project.history()) do if same(item.root, root) then count = count + 1 end end
  assert(count == 1, 'Canonical aliases created duplicate MRU projects')
end
local function functional(paths)
  local project, native = require('config.project'), require('config.project_native')
  project.activate(paths.parent, { restore = false, pick = false })
  local source = vim.fs.joinpath(paths.parent, 'main.cpp')
  fn.writefile({ 'struct Counter { int value = 1; };', 'int main() { Counter counter; return counter.value; }' }, source)
  vim.cmd.edit(fn.fnameescape(source))
  local editor, editor_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  if vim.lsp.is_enabled('clangd') then
    wait_for(function() return #vim.lsp.get_clients({ bufnr = editor, name = 'clangd' }) > 0 end, 'clangd did not attach to the preservation fixture', 30000)
  else print('SKIP project LSP preservation: clangd is unavailable') end
  api.nvim_buf_set_lines(editor, 0, 0, false, { '// unsaved project-launch fixture' })
  local text, tick = api.nvim_buf_get_lines(editor, 0, -1, true), api.nvim_buf_get_changedtick(editor)
  local terminal = terminal_session()
  api.nvim_set_current_win(editor_win)
  local before_windows, before_clients = windows(), clients(editor)
  local before_cwd, before_root, before_win = fn.getcwd(), project.root(), api.nvim_get_current_win()
  local target_file = vim.fs.joinpath(paths.target, "文件 空格 &';$.txt")
  fn.writefile({ 'new-window file fixture' }, target_file)
  local calls = {}
  original_launch, original_folder, original_file = native.launch, native.choose_folder, native.choose_file
  native.launch = function(kind, path) calls[#calls + 1] = { kind = kind, path = path }; return true end
  local function unchanged()
    assert(fn.getcwd() == before_cwd and project.root() == before_root, 'Launching another window changed the parent project/cwd')
    assert(api.nvim_get_current_win() == before_win and vim.deep_equal(windows(), before_windows), 'Launching another window changed parent windows/focus')
    assert(vim.bo[editor].modified and api.nvim_buf_get_changedtick(editor) == tick
      and vim.deep_equal(api.nvim_buf_get_lines(editor, 0, -1, true), text), 'Launching another window changed or saved the modified buffer')
    assert(vim.deep_equal(clients(editor), before_clients), 'Launching another window detached or restarted an LSP client')
    local job_state = fn.jobwait({ terminal.job }, 0)[1]
    assert(job_state == -1, 'Launching another window stopped the terminal process: ' .. vim.inspect({ wait = job_state, channel = api.nvim_get_chan_info(terminal.job), sessions = require('config.terminal').sessions(paths.parent) }))
    local sessions = require('config.terminal').sessions(paths.parent)
    assert(#sessions == 1 and sessions[1].job == terminal.job, 'Launching another window replaced its terminal session')
  end
  project.open(paths.target); unchanged()
  assert(calls[#calls].kind == 'project' and same(calls[#calls].path, paths.target), 'Open folder did not request a new project window')
  local command_count = #calls
  -- A typed path or native Ex completion escapes spaces/special characters.
  -- Execute the real user command so its args/fargs parsing is exercised.
  vim.cmd('ProjectOpen ' .. fn.fnameescape(paths.target))
  assert(#calls == command_count + 1 and calls[#calls].kind == 'project'
    and same(calls[#calls].path, paths.target), 'ProjectOpen did not decode the completed Ex path before launching')
  unchanged()
  project.open_file(target_file); unchanged()
  assert(calls[#calls].kind == 'file' and same(calls[#calls].path, target_file), 'Open file did not request a separate file window')
  project.home(); unchanged()
  assert(calls[#calls].kind == 'home', 'Home did not request an independent launcher window')
  local count = #calls
  local folder_dialogs = 0
  native.choose_folder = function(callback) folder_dialogs = folder_dialogs + 1; callback(nil, nil) end
  native.choose_file = function(callback) callback(nil, nil) end
  vim.cmd('ProjectOpen'); project.open_file(); unchanged()
  assert(folder_dialogs == 1, 'ProjectOpen without arguments did not open the native folder chooser')
  assert(#calls == count, 'Cancelling a system dialog launched another process')

  require('config.project_history').record(paths.target)
  for _, action_name in ipairs({ 'select_default', 'select_vertical' }) do
    local launch_count = #calls
    project.recent()
    local prompt
    wait_for(function()
      for _, win in ipairs(api.nvim_list_wins()) do
        local buf = api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == 'TelescopePrompt' then prompt = buf; return true end
      end
      return false
    end, 'Recent projects did not render a Telescope picker')
    local picker = require('telescope.actions.state').get_current_picker(prompt)
    wait_for(function() return picker.manager and picker.manager:num_results() > 0 end, 'Recent project picker stayed empty')
    picker:set_selection(picker:get_row(1))
    local selected = assert(picker:get_selection(), 'Recent project picker did not select a project').value.root
    require('telescope.actions')[action_name](prompt)
    wait_for(function() return #calls == launch_count + 1 end, 'Recent project ' .. action_name .. ' did not request a new window')
    assert(calls[#calls].kind == 'project' and same(calls[#calls].path, selected),
      'Recent project ' .. action_name .. ' launched the wrong project')
    unchanged()
  end

  local missing = directory('missing-project')
  require('config.project_history').record(missing)
  assert(vim.uv.fs_rmdir(missing), 'Could not remove the empty missing-project fixture')
  assert(history_item(project, missing).exists == false, 'Missing recent projects were not marked unavailable')
  project.forget(missing)
  assert(not history_item(project, missing), 'Forgetting a recent project kept its record')
  project.forget(paths.target)
  assert(fn.isdirectory(paths.target) == 1 and fn.filereadable(target_file) == 1, 'Forgetting a recent project removed source files')
  print('PASS projects parent isolation: explicit root, modified buffer, windows/focus, real terminal job, LSP, native-dialog cancel, real Telescope recent selection')
end
local function saved_view(win)
  return api.nvim_win_call(win, function()
    local view = fn.winsaveview()
    return { lnum = view.lnum, col = view.col, topline = view.topline, leftcol = view.leftcol }
  end)
end
local function session_save(paths)
  local project = require('config.project')
  project.activate(paths.session, { restore = false, pick = false })
  local one, two = vim.fs.joinpath(paths.session, 'one.txt'), vim.fs.joinpath(paths.session, 'two.txt')
  local lines = {}; for index = 1, 160 do lines[index] = ('line %03d session fixture'):format(index) end
  fn.writefile(lines, one); fn.writefile(lines, two)
  vim.cmd.edit(fn.fnameescape(one))
  local one_win, one_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  vim.cmd.vsplit(fn.fnameescape(two))
  local two_win, two_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  api.nvim_win_call(one_win, function() fn.winrestview({ lnum = 44, col = 3, topline = 32, leftcol = 0 }) end)
  api.nvim_win_call(two_win, function() fn.winrestview({ lnum = 22, col = 5, topline = 10, leftcol = 0 }) end)
  local expected = { [normalize(one)] = saved_view(one_win), [normalize(two)] = saved_view(two_win) }
  fn.writefile({ vim.json.encode(expected) }, vim.fs.joinpath(base, 'session-views.json'))

  -- Each existing code split is now replaced, not supplemented, by a terminal.
  api.nvim_set_current_win(one_win)
  local first = terminal_session()
  assert(api.nvim_get_current_win() == one_win and api.nvim_win_get_buf(one_win) == first.bufnr,
    'First terminal must replace its code window in-place')
  api.nvim_set_current_win(two_win)
  local second = terminal_session()
  assert(api.nvim_get_current_win() == two_win and api.nvim_win_get_buf(two_win) == second.bufnr,
    'Second terminal must replace its code window in-place')
  assert(#api.nvim_tabpage_list_wins(0) == 2 and #fn.win_findbuf(one_buf) == 0 and #fn.win_findbuf(two_buf) == 0,
    'Session fixture must have no visible code window while both editors remain hidden')

  fn.setqflist({ { filename = one, lnum = 3, text = 'temporary quickfix' } })
  vim.cmd.copen()
  local quickfix_win = api.nvim_get_current_win()
  local float_buf = api.nvim_create_buf(false, true)
  local float_win = api.nvim_open_win(float_buf, false, { relative = 'editor', row = 1, col = 1, width = 12, height = 2 })
  api.nvim_set_current_win(two_win)
  vim.cmd.stopinsert()
  local before, focus, views, display_options = windows(), api.nvim_get_current_win(), {}, {}
  local mode = fn.mode(1)
  local option_names = { 'number', 'relativenumber', 'signcolumn', 'cursorline', 'winfixheight' }
  for _, entry in ipairs(before) do
    local win = entry[1]
    views[win], display_options[win] = saved_view(win), {}
    for _, name in ipairs(option_names) do display_options[win][name] = api.nvim_get_option_value(name, { win = win }) end
  end
  assert(project.save_session(), 'ProjectSaveSession did not save the covered file workspace')
  assert(api.nvim_get_current_win() == focus and vim.deep_equal(windows(), before),
    'Session saving changed terminal windows, buffers or focus')
  assert(fn.mode(1) == mode, 'Session saving changed the input mode')
  for _, entry in ipairs(before) do
    local win = entry[1]
    assert(vim.deep_equal(saved_view(win), views[win]), 'Session saving changed a visible terminal/quickfix/float view')
    for _, name in ipairs(option_names) do
      assert(api.nvim_get_option_value(name, { win = win }) == display_options[win][name],
        'Session saving changed a visible window option: ' .. name)
    end
  end
  for _, session in ipairs({ first, second }) do
    assert(api.nvim_buf_is_valid(session.bufnr) and fn.jobwait({ session.job }, 0)[1] == -1,
      'Session saving stopped or replaced a terminal process')
  end
  local saved = table.concat(fn.readfile(require('config.project_session').file()), '\n')
  assert(not saved:find('term://', 1, true), 'Saved session contains a terminal buffer')
  local edited_one, edited_two = false, false
  for _, line in ipairs(fn.readfile(require('config.project_session').file())) do
    if line:find('edit ', 1, true) then
      edited_one = edited_one or line:find('one.txt', 1, true) ~= nil
      edited_two = edited_two or line:find('two.txt', 1, true) ~= nil
    end
  end
  assert(edited_one and edited_two, 'Saved session must restore both code windows, not only hidden-buffer badd entries')
  -- Remove only the temporary UI fixtures after checking save did not touch
  -- them. Native mksession scales top lines when an excluded quickfix split
  -- changes window heights; the exit regression must use the original geometry.
  api.nvim_win_close(float_win, true)
  api.nvim_win_close(quickfix_win, true)
  assert(#api.nvim_tabpage_list_wins(0) == 2 and api.nvim_win_get_buf(one_win) == first.bufnr
    and api.nvim_win_get_buf(two_win) == second.bufnr, 'Exit fixture must retain both terminal replacements')
  print('PASS project session saved hidden code buffers/views behind two live terminal replacements; visible UI/jobs unchanged')
end
local function session_restore(paths)
  local project = require('config.project')
  local restored = project.activate(paths.session, { restore = true, pick = false })
  assert(restored, 'A second process did not find and restore the saved project session')
  local expected = vim.json.decode(table.concat(fn.readfile(vim.fs.joinpath(base, 'session-views.json')), '\n'))
  local found = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    assert(api.nvim_win_get_config(win).relative == '', 'Session restored a floating window')
    local buf = api.nvim_win_get_buf(win)
    assert(vim.bo[buf].buftype == '', 'Session restored a terminal/quickfix window')
    local name = normalize(api.nvim_buf_get_name(buf))
    assert(expected[name], 'Session restored an unexpected buffer: ' .. api.nvim_buf_get_name(buf))
    assert(vim.deep_equal(saved_view(win), expected[name]), 'Session lost the saved code view for ' .. name
      .. ': ' .. vim.inspect({ expected = expected[name], actual = saved_view(win) }))
    found[name] = true
  end
  assert(vim.tbl_count(found) == 2 and #api.nvim_tabpage_list_wins(0) == 2, 'Session did not restore exactly two file splits')
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then assert(vim.bo[buf].buftype ~= 'terminal' and vim.bo[buf].buftype ~= 'quickfix', 'Session revived an excluded buffer') end
  end
  print('PASS project session restored across processes after direct :qa with live terminals: two code files, exact cursors/toplines/splits, no terminal/quickfix/float')
end
local function child_arguments()
  local early = ('lua vim.g.my_nvim_root=%q; vim.opt.rtp:prepend(%q); local m=require("config.machine").load(); m.autosave={enabled=false}; m.project=vim.tbl_extend("force",m.project or {},{state_dir=%q})')
    :format(config_root, config_root, state_dir)
  return { vim.v.progpath, '--headless', '-i', 'NONE', '--cmd', early, '-u', vim.fs.joinpath(config_root, 'init.lua'),
    '-c', ('lua dofile(%q)'):format(script) }
end
local function spawn(child_stage)
  local env = require('config.project_native').child_env()
  env.MY_NVIM_PROJECT_TEST_STAGE, env.MY_NVIM_PROJECT_TEST_BASE = child_stage, base
  local child = vim.system(child_arguments(), { text = true, cwd = base, env = env, clear_env = true })
  children[#children + 1] = child
  return child
end
local function completed(child, label)
  local result = child:wait(60000)
  assert(result.code == 0, label .. ' failed (exit ' .. tostring(result.code) .. '):\n' .. (result.stdout or '') .. (result.stderr or ''))
  print(vim.trim((result.stdout or '') .. (result.stderr or '')))
end
local function run()
  fn.mkdir(base, 'p')
  local paths = fixtures()
  if stage then
    assert(same(require('config.project_history').base_dir(), state_dir), 'Project state escaped the disposable test directory')
    if stage == 'empty' then simple(paths.empty)
    elseif stage == 'weird' then simple(paths.weird)
    elseif stage == 'functional' then functional(paths)
    elseif stage == 'session-save' then session_save(paths)
    elseif stage == 'session-restore' then session_restore(paths)
    elseif stage == 'mru-a' or stage == 'mru-b' then
      fn.writefile({ 'ready' }, vim.fs.joinpath(base, stage .. '.ready'))
      wait_for(function() return fn.filereadable(vim.fs.joinpath(base, 'mru-go')) == 1 end, 'Concurrent MRU writer never received the barrier', 20000)
      simple(stage == 'mru-a' and paths.concurrent_a or paths.concurrent_b)
    elseif stage == 'mru-check' then
      local project = require('config.project')
      assert(history_item(project, paths.concurrent_a) and history_item(project, paths.concurrent_b), 'Concurrent MRU writers overwrote another project record')
      print('PASS concurrent project MRU: both independent-process updates survived')
    else error('Unknown project test stage: ' .. stage) end
    return
  end
  completed(spawn('empty'), 'Empty non-Git project')
  completed(spawn('weird'), 'Unicode/special-character project')
  completed(spawn('functional'), 'Parent-window isolation')
  completed(spawn('session-save'), 'Session save')
  completed(spawn('session-restore'), 'Cross-process session restore')
  local first, second = spawn('mru-a'), spawn('mru-b')
  wait_for(function() return fn.filereadable(vim.fs.joinpath(base, 'mru-a.ready')) == 1
    and fn.filereadable(vim.fs.joinpath(base, 'mru-b.ready')) == 1 end, 'Concurrent Neovim processes did not reach the MRU barrier', 20000)
  fn.writefile({ 'go' }, vim.fs.joinpath(base, 'mru-go'))
  completed(first, 'Concurrent writer A'); completed(second, 'Concurrent writer B')
  completed(spawn('mru-check'), 'Concurrent MRU verification')
  print('PASS projects: empty/non-Git/special paths, parent state isolation, real cross-process persistence, concurrent MRU, missing/forgotten project records; fixtures: ' .. base)
end
vim.schedule(function()
  local ok, err = xpcall(run, debug.traceback)
  cleanup()
  if not ok then api.nvim_err_writeln(err); vim.cmd('cquit 1') else vim.cmd('qa!') end
end)
