-- nvim --headless -c "lua dofile(vim.fn.stdpath('config') .. '/tests/project_native.lua')"
-- Native launch plans and dialog response handling, without opening GUI windows.
assert(vim.g.my_nvim_ready, 'Load the my-nvim configuration before this test')
local native = require('config.project_native')
local api, fn = vim.api, vim.fn
local base = vim.fs.joinpath(fn.stdpath('cache'), 'my-nvim-project-native-tests', tostring(vim.uv.os_getpid()))
local folder = vim.fs.joinpath(base, "项目 空格 &';$%{1+1}目录")
local file = vim.fs.joinpath(folder, "笔记 空格 &';$.txt")
fn.mkdir(folder, 'p')
fn.writefile({ 'native argument fixture' }, file)
local original_spawn, original_system = vim.uv.spawn, vim.system
local original_title = { title = vim.o.title, titlelen = vim.o.titlelen, titlestring = vim.o.titlestring }
require('config.ai_completion').setup({ deepseek = { enabled = false } })
vim.o.swapfile = false
local original_environment = {}
local removed = { 'NVIM', 'NVIM_LISTEN_ADDRESS', 'NVIM_LOG_FILE', 'NVIM_SERVERNAME', 'SERVERNAME', 'VIM', 'VIMRUNTIME', 'MYVIMRC' }
for _, key in ipairs(removed) do original_environment[key] = vim.env[key] or false end
local machine = require('config.machine').load()
local function cleanup()
  vim.uv.spawn, vim.system = original_spawn, original_system
  for name, value in pairs(original_title) do vim.o[name] = value end
  for key, value in pairs(original_environment) do vim.env[key] = value ~= false and value or nil end
  native.setup(machine)
end
local function same_path(left, right)
  left, right = vim.fs.normalize(left), vim.fs.normalize(right)
  if fn.has('win32') == 1 then return left:lower() == right:lower() end
  return left == right
end
local function decoded_windows(value) return value:gsub(string.char(92) .. ';', ';') end
local function contains(argv, value, decode)
  local count = 0
  for _, argument in ipairs(argv) do
    if (decode and decoded_windows(argument) or argument) == value then count = count + 1 end
  end
  return count
end
local function response_case(method, response, expected, expected_error)
  local captured, called, selected, failure
  vim.system = function(argv, options, callback)
    captured = { argv = argv, options = options }
    callback(response)
    return {}
  end
  native[method](function(path, err) called, selected, failure = true, path, err end)
  assert(vim.wait(1000, function() return called end, 10), 'Dialog callback was not delivered')
  vim.system = original_system
  assert(captured.options.clear_env == true, 'Dialog did not use an independent child environment')
  if expected_error then assert(type(failure) == 'string' and failure ~= '', 'Dialog failure was silently discarded')
  else assert(failure == nil, failure) end
  if expected then assert(selected and same_path(selected, expected), 'Dialog changed a selected Unicode/special-character path')
  else assert(selected == nil, 'Cancelled/failed dialog returned a file') end
end

local function run()
  native.setup({})
  local parent_cwd, parent_path = fn.getcwd(), vim.env.PATH
  for _, key in ipairs(removed) do vim.env[key] = 'parent sentinel ' .. key end
  local env = native.child_env()
  for _, key in ipairs(removed) do
    assert(env[key] == nil and vim.env[key] == 'parent sentinel ' .. key, 'Child environment changed/inherited ' .. key)
  end
  assert((env.PATH or env.Path or env.path) == parent_path, 'Child environment discarded the user PATH')
  env.PATH = 'test mutation'
  assert(vim.env.PATH == parent_path, 'Child environment aliases the parent environment')

  for _, platform in ipairs({ 'windows', 'macos' }) do
    local project, project_error = native.build_launch('project', folder, platform)
    assert(project, project_error)
    assert(same_path(project.cwd, folder), 'Project launch cwd lost special characters')
    local decode = platform == 'windows'
    assert(contains(project.argv, folder, decode) == 1, 'Project path must remain one argv element')
    assert(contains(project.argv, '--cmd') == 1 and contains(project.argv, 'let g:my_nvim_project_launch = 1') == 1,
      'Project startup marker must be a constant command, separate from untrusted paths')
    local single, file_error = native.build_launch('file', file, platform)
    assert(single, file_error)
    assert(same_path(single.cwd, folder) and contains(single.argv, file, decode) == 1, 'File launch split or changed its path')
    assert(contains(single.argv, '--cmd') == 0 and contains(single.argv, '--') >= 1, 'Single-file launch should preserve normal file startup')
    if platform == 'windows' then
      assert(contains(project.argv, '--window') == 1 and contains(project.argv, 'new') == 1,
        'Windows launch must request an independent terminal window')
      local title_index
      for index, argument in ipairs(project.argv) do if argument == '--title' then title_index = index end end
      assert(title_index and decoded_windows(project.argv[title_index + 1]) == vim.fs.basename(folder)
        and contains(project.argv, '--suppressApplicationTitle') == 1,
        'WT project title must be a single literal folder name and resist child shell title changes')
      assert(contains(single.argv, '--title') == 0 and contains(single.argv, '--suppressApplicationTitle') == 0,
        'Single-file launch inherited the fixed project title')
      for index = 2, #single.argv do
        local argument = single.argv[index]
        for position = 1, #argument do
          if argument:sub(position, position) == ';' then
            assert(argument:sub(position - 1, position - 1) == string.char(92), 'WT semicolon separator was not escaped')
          end
        end
      end
    else
      assert(project.argv[1] == '/usr/bin/osascript' and contains(project.argv, folder) == 1,
        'macOS launch should pass raw paths to its AppleScript helper')
    end
    local home, home_error = native.build_launch('home', nil, platform)
    assert(home, home_error)
    assert(contains(home.argv, '--cmd') == 0 and contains(home.argv, file, decode) == 0, 'Home launch inherited a project/file argument')
    assert(contains(home.argv, '--title') == 0 and contains(home.argv, '--suppressApplicationTitle') == 0,
      'Home launch inherited the fixed project title')
    for _, key in ipairs(removed) do assert(home.env[key] == nil, 'Launch plan leaked ' .. key) end
  end
  assert(fn.getcwd() == parent_cwd and vim.env.PATH == parent_path, 'Constructing launch plans changed the parent process')
  for name, value in pairs(original_title) do
    assert(vim.o[name] == value, 'Constructing launch plans changed the parent title option ' .. name)
  end
  native.set_project_title(folder)
  assert(vim.o.title and vim.o.titlelen == 0 and vim.o.titlestring == "项目 空格 &';$%%{1+1}目录",
    'Project title did not preserve literal percent expressions')
  native.set_project_title('synthetic/控制' .. string.char(27) .. '\n%{1+1}目录')
  assert(vim.o.titlestring == '控制  %%{1+1}目录' and not vim.o.titlestring:find('%c'),
    'Project title allowed control characters or an executable title expression')
  for name, value in pairs(original_title) do vim.o[name] = value end

  native.setup({ project = { launcher = { 'terminal-app', '--cwd', '{cwd}', '--', '{nvim}', '{file}' } } })
  local custom = assert(native.build_launch('file', file, 'windows'))
  assert(custom.argv[1] == 'terminal-app' and contains(custom.argv, file) == 1 and contains(custom.argv, folder) == 1,
    'Custom launcher argv substitutions must preserve literal paths')
  local project_custom = assert(native.build_launch('project', folder, 'windows'))
  assert(contains(project_custom.argv, '{file}') == 0 and contains(project_custom.argv, '--cmd') == 1, 'Custom project launch retained a file placeholder')
  native.setup({ project = { launcher = { 'terminal-app', '{cwd}' } } })
  local invalid, invalid_error = native.build_launch('project', folder)
  assert(not invalid and invalid_error, 'A custom launcher without {nvim} was accepted')
  native.setup({})
  assert(not native.build_launch('project', file), 'A file was accepted as a project folder')
  assert(not native.build_launch('file', folder), 'A directory was accepted as a single file')
  assert(not native.build_launch('unknown', folder), 'An unknown launch kind was accepted')

  local spawn, unreferenced, closed, on_exit
  vim.uv.spawn = function(executable, options, callback)
    spawn, on_exit = { executable = executable, options = options }, callback
    return { unref = function() unreferenced = true end, is_closing = function() return false end,
      close = function() closed = true end }, 12345
  end
  local launched, launch_error = native.launch('project', folder)
  assert(launched, launch_error)
  assert(spawn and spawn.options.detached == true and unreferenced, 'Launch did not detach the child from the parent editor')
  assert(same_path(spawn.options.cwd, folder), 'Spawn changed the cwd path')
  for _, value in ipairs(spawn.options.env) do
    local key = value:match('^([^=]+)=')
    assert(not vim.tbl_contains(removed, key and key:upper()), 'Spawn inherited an editor-control environment variable')
  end
  on_exit(0, 0)
  assert(closed, 'Launch completion did not release its process handle')
  vim.uv.spawn = original_spawn

  -- Restore actual environment values before invoking a real helper process.
  for key, value in pairs(original_environment) do vim.env[key] = value ~= false and value or nil end
  local windows = fn.has('win32') == 1
  local function payload(path) return windows and vim.json.encode({ path = path }) or (path .. '\n') end
  response_case('choose_folder', { code = 0, stdout = payload(folder) }, folder)
  response_case('choose_file', { code = 0, stdout = payload(file) }, file)
  response_case('choose_folder', { code = 0, stdout = windows and '{"cancelled":true}' or '' }, nil)
  response_case('choose_file', { code = 1, stdout = '', stderr = 'fixture dialog error' }, nil, true)
  response_case('choose_file', { code = 0, stdout = payload(folder) }, nil, true)
  if windows then
    local environment = native.child_env()
    for key in pairs(environment) do if key:upper() == 'PSMODULEPATH' then environment[key] = nil end end
    local helper = vim.fs.joinpath(vim.g.my_nvim_root, 'scripts/windows_dialog.ps1')
    for _, mode in ipairs({ 'folder', 'file' }) do
      local result = vim.system({ 'powershell.exe', '-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
        '-File', helper, '-Mode', mode, '-InitialDirectory', folder, '-CancelForTest' },
        { text = true, env = environment, clear_env = true }):wait(15000)
      assert(result.code == 0, 'Native dialog cancellation helper failed: ' .. (result.stderr or ''))
      assert(vim.json.decode(result.stdout).cancelled == true, 'Native helper did not return cancellation JSON')
    end
  end
  print('PASS project_native: literal Unicode/special paths and titles, WT fixed project title/home-file isolation, control filtering, semicolon quoting, macOS argv, custom launcher, detached spawn, isolated environment, dialog selection/cancel/errors, native Windows cancel helper')
end

vim.schedule(function()
  local ok, err = xpcall(run, debug.traceback)
  cleanup()
  if not ok then api.nvim_err_writeln(err); vim.cmd('cquit 1') else vim.cmd('qa!') end
end)
