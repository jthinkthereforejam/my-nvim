-- nvim --headless -c "lua dofile(vim.fn.stdpath('config') .. '/tests/project_startup.lua')"
-- Uses Neovim's MessagePack codec and real embedded UI attachment. No GUI window.
assert(vim.g.my_nvim_ready, 'Load the my-nvim configuration before this test')
-- This suite exercises explicit saves and preservation of unsaved buffers.
require('config.autosave').setup({ autosave = { enabled = false } })
require('config.ai_completion').setup({ deepseek = { enabled = false } })
vim.o.swapfile = false
local api, fn, uv = vim.api, vim.fn, vim.uv
local config_root = assert(vim.g.my_nvim_root)
local base = vim.fs.joinpath(fn.stdpath('cache'), 'my-nvim-project-startup-tests', tostring(uv.os_getpid()))
local state_dir = vim.fs.joinpath(base, 'state')
local children = {}
fn.mkdir(base, 'p')
local function close(handle) if handle and not handle:is_closing() then handle:close() end end
local function environment_list(env)
  local result = {}; for key, value in pairs(env) do result[#result + 1] = key .. '=' .. value end; return result
end
local function normalize(path)
  path = vim.fs.normalize(uv.fs_realpath(path) or path):gsub('[/\\]+$', '')
  return fn.has('win32') == 1 and path:lower() or path
end
local function spawn(arguments, cwd, headless)
  local early = ('lua vim.g.my_nvim_root=%q; vim.opt.rtp:prepend(%q); vim.o.swapfile=false; local m=require("config.machine").load(); m.autosave={enabled=false}; m.deepseek={enabled=false}; m.project=vim.tbl_extend("force",m.project or {},{state_dir=%q})')
    :format(config_root, config_root, state_dir)
  local argv = { '--embed', '-i', 'NONE', '--cmd', early, '-u', vim.fs.joinpath(config_root, 'init.lua') }
  if headless then table.insert(argv, 1, '--headless') end
  vim.list_extend(argv, arguments or {})
  local client = { stdin = uv.new_pipe(false), stdout = uv.new_pipe(false), stderr = uv.new_pipe(false),
    responses = {}, serial = 0, errors = {}, notifications = 0, titles = {} }
  children[#children + 1] = client
  client.handle = assert(uv.spawn(vim.v.progpath, { args = argv, cwd = cwd or base,
    env = environment_list(require('config.project_native').child_env()), hide = true,
    stdio = { client.stdin, client.stdout, client.stderr } }, function(code, signal)
    client.exited = { code = code, signal = signal }
    close(client.handle)
  end))
  local unpack = vim.mpack.Unpacker()
  client.stdout:read_start(function(err, chunk)
    if err then client.protocol_error = tostring(err) end
    if not chunk then return end
    local position = 1
    while position <= #chunk do
      local ok, message, next_position = pcall(unpack, chunk, position)
      if not ok then client.protocol_error = tostring(message); return end
      position = next_position
      if message then
        if message[1] == 1 then client.responses[message[2]] = message
        elseif message[1] == 2 then
          client.notifications = client.notifications + 1
          if message[2] == 'redraw' then
            for _, event in ipairs(message[3]) do
              if event[1] == 'set_title' then
                for index = 2, #event do client.titles[#client.titles + 1] = event[index][1] end
              end
            end
          end
        elseif message[1] == 0 then
          client.stdin:write(vim.mpack.encode({ 1, message[2], { 0, 'UI test does not implement client requests' }, vim.NIL }))
        end
      end
    end
  end)
  client.stderr:read_start(function(err, chunk)
    if err then client.errors[#client.errors + 1] = tostring(err) end
    if chunk then client.errors[#client.errors + 1] = chunk end
  end)
  function client:request(method, parameters)
    self.serial = self.serial + 1
    local id = self.serial
    assert(not self.exited, 'Embedded Neovim exited before ' .. method .. ': ' .. table.concat(self.errors))
    self.stdin:write(vim.mpack.encode({ 0, id, method, parameters or {} }))
    assert(vim.wait(20000, function() return self.responses[id] ~= nil or self.exited ~= nil or self.protocol_error ~= nil end, 10),
      'Embedded Neovim RPC timed out: ' .. method)
    assert(not self.protocol_error, self.protocol_error)
    local response = self.responses[id]
    assert(response, 'Embedded Neovim exited during ' .. method .. ': ' .. table.concat(self.errors))
    self.responses[id] = nil
    assert(response[3] == nil or response[3] == vim.NIL, 'Embedded API failure: ' .. vim.inspect(response[3]))
    return response[4]
  end
  function client:lua(code, arguments) return self:request('nvim_exec_lua', { code, arguments or {} }) end
  function client:shutdown()
    if not self.exited then
      pcall(self.stdin.write, self.stdin, vim.mpack.encode({ 2, 'nvim_command', { 'qa!' } }))
      vim.wait(5000, function() return self.exited ~= nil end, 10)
    end
    if not self.exited then pcall(self.handle.kill, self.handle, 15); vim.wait(3000, function() return self.exited ~= nil end, 10) end
    close(self.stdin); close(self.stdout); close(self.stderr); close(self.handle)
  end
  return client
end
local snapshot_code = [[
  local dashboard = false
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'snacks_dashboard' then dashboard = true end
  end
  return { ready = vim.g.my_nvim_ready == true, root = require('config.project').root() or vim.NIL,
    cwd = vim.fn.getcwd(), file = vim.api.nvim_buf_get_name(0), filetype = vim.bo.filetype,
    argc = vim.fn.argc(-1), dashboard = dashboard, uis = #vim.api.nvim_list_uis(),
    title = vim.o.title, titlestring = vim.o.titlestring, titlelen = vim.o.titlelen }
]]
local function ready(client)
  local result
  assert(vim.wait(20000, function()
    result = client:lua(snapshot_code)
    return result.ready
  end, 20), 'Embedded configuration never became ready')
  return result
end
local function attach(client)
  client:request('nvim_ui_attach', { 120, 40, { ext_linegrid = true, rgb = true } })
  return ready(client)
end
local function project_title(client, root, context)
  local expected = vim.fs.basename(root)
  client:request('nvim_command', { 'redraw' })
  local state
  assert(vim.wait(5000, function()
    state = client:lua(snapshot_code)
    return state.title and state.titlelen == 0 and client.titles[#client.titles] == expected
  end, 10), context .. ' did not send the literal folder title in a real UI set_title event: ' .. vim.inspect(client.titles))
  assert(state.titlestring == expected:gsub('%%', '%%%%'), context .. ' lost title percent escaping')
end
local function no_project_title(state, context)
  assert(not state.title and state.titlestring == '', context .. ' inherited project title options')
end
local function cleanup() for _, client in ipairs(children) do pcall(client.shutdown, client) end end
local function run()
  local headless = spawn({}, base, true)
  local hidden = ready(headless)
  assert(hidden.uis == 0 and not hidden.dashboard and hidden.root == vim.NIL, 'Headless no-argument startup rendered a welcome UI or bound a project')
  headless:shutdown()

  local home = spawn({}, base)
  attach(home)
  local home_state
  assert(vim.wait(10000, function() home_state = home:lua(snapshot_code); return home_state.dashboard end, 20),
    'No-argument startup did not render the real Snacks dashboard after UI attachment')
  assert(home_state.root == vim.NIL and home_state.argc == 0 and home_state.uis == 1,
    'Welcome UI inherited a project/file startup context')
  assert(home.notifications > 0, 'The embedded UI never received actual redraw notifications')
  no_project_title(home_state, 'Welcome startup')
  home:shutdown()

  local folder = vim.fs.joinpath(base, "目录 空格 &';$%{1+1}项目")
  local launched = vim.fs.joinpath(base, 'marker %{1+1}项目')
  fn.mkdir(folder, 'p'); fn.mkdir(launched, 'p')
  local file = vim.fs.joinpath(base, "单文件 空格 &';$.txt")
  fn.writefile({ 'single-file startup fixture' }, file)
  local single = spawn({ '--', file }, base)
  local single_state = attach(single)
  assert(single_state.root == vim.NIL and not single_state.dashboard and normalize(single_state.file) == normalize(file),
    'Single-file startup showed the dashboard, activated a project, or changed its file path')
  no_project_title(single_state, 'Single-file startup')
  single:shutdown()

  local directory = spawn({ '--', folder }, base)
  attach(directory)
  local directory_state
  assert(vim.wait(10000, function()
    directory_state = directory:lua(snapshot_code)
    return directory_state.root ~= vim.NIL and directory_state.filetype == 'project_empty'
  end, 20), 'Directory startup did not enter its explicit empty-project context')
  assert(normalize(directory_state.root) == normalize(folder) and normalize(directory_state.cwd) == normalize(folder)
    and not directory_state.dashboard and directory_state.argc == 0, 'Directory startup lost its root or opened netrw/home')
  project_title(directory, folder, 'Directory startup')
  local first, second = vim.fs.joinpath(folder, 'first.txt'), vim.fs.joinpath(folder, 'second.txt')
  fn.writefile({ 'first title fixture' }, first); fn.writefile({ 'second title fixture' }, second)
  for _, path in ipairs({ first, second }) do
    directory:lua('vim.cmd.edit(vim.fn.fnameescape(...))', { path })
    project_title(directory, folder, 'Switching code files')
  end
  local terminal_state = directory:lua([[
    local shell = vim.fn.has('win32') == 1
      and { 'powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '[System.Threading.Thread]::Sleep(120000)' }
      or { '/bin/sleep', '120' }
    local terminal = require('config.terminal')
    terminal.setup({ terminal = { shell = shell } })
    local status = terminal.toggle('n')
    assert(vim.bo.buftype == 'terminal' and status.visible, 'Integrated terminal did not replace the editor')
    assert(vim.fn.jobwait({ status.session.job }, 0)[1] == -1, 'Title test shell exited early')
    return { buftype = vim.bo.buftype, job = status.session.job }
  ]])
  assert(terminal_state.buftype == 'terminal', 'Terminal title fixture is not a real terminal buffer')
  project_title(directory, folder, 'Integrated terminal')
  directory:lua([[
    vim.cmd.stopinsert()
    local status = require('config.terminal').toggle('n')
    assert(not status.visible and vim.bo.buftype == '', 'Integrated terminal did not return to code')
  ]])
  project_title(directory, folder, 'Returning from terminal')
  assert(directory:lua('return require("config.project").save_session()'), 'Title fixture session was not saved')
  directory:shutdown()

  local restored = spawn({ '--', folder }, base)
  attach(restored)
  local restored_state
  assert(vim.wait(10000, function()
    restored_state = restored:lua(snapshot_code)
    return restored_state.root ~= vim.NIL and normalize(restored_state.file) == normalize(second)
  end, 20), 'Project session did not restore its code file in a new process')
  project_title(restored, folder, 'Restored project session')
  restored:shutdown()

  local marker = spawn({ '--cmd', 'let g:my_nvim_project_launch = 1' }, launched)
  attach(marker)
  local marker_state
  assert(vim.wait(10000, function()
    marker_state = marker:lua(snapshot_code)
    return marker_state.root ~= vim.NIL and marker_state.filetype == 'project_empty'
  end, 20), 'Native launcher marker did not activate its working directory')
  assert(normalize(marker_state.root) == normalize(launched) and normalize(marker_state.cwd) == normalize(launched)
    and not marker_state.dashboard, 'Native project startup displayed the home screen')
  project_title(marker, launched, 'Native launcher marker')
  marker:shutdown()
  print('PASS project_startup: no headless home, real embedded welcome UI/redraw/set_title, home-file title isolation, literal Unicode/percent project titles, directory/native-marker startup, file and real terminal switches, restored-session title, empty-project view')
end
vim.schedule(function()
  local ok, err = xpcall(run, debug.traceback)
  cleanup()
  if not ok then api.nvim_err_writeln(err); vim.cmd('cquit 1') else vim.cmd('qa!') end
end)
