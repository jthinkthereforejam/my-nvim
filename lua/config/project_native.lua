-- Native dialogs and independent terminal windows. No editor state is changed here.
local M = {}
local settings = { terminal_profile = 'Neovim' }
local windows = vim.fn.has('win32') == 1
local root = vim.g.my_nvim_root
  or vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
local removed_environment = {
  NVIM = true, NVIM_LISTEN_ADDRESS = true, NVIM_LOG_FILE = true,
  NVIM_SERVERNAME = true, SERVERNAME = true, VIM = true, VIMRUNTIME = true, MYVIMRC = true, VIMINIT = true, EXINIT = true,
}

function M.setup(machine)
  settings = vim.tbl_extend('force', { terminal_profile = 'Neovim' }, (machine or {}).project or {})
end

function M.child_env()
  local env = {}
  for key, value in pairs(vim.fn.environ()) do
    if not removed_environment[key:upper()] then env[key] = value end
  end
  return env
end

local function absolute(path)
  if type(path) ~= 'string' or path == '' then return nil end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
end

local function project_title(path)
  -- Titles are plain data. Strip terminal controls, and escape statusline %
  -- separately when installing Neovim's titlestring.
  local name = vim.fs.basename(path)
  if not name or name == '' then name = path end
  return name:gsub('%c', ' ')
end

function M.set_project_title(path)
  vim.o.titlestring = project_title(path):gsub('%%', '%%%%')
  vim.o.titlelen = 0
  vim.o.title = true
end

local function launch_context(kind, path)
  if kind ~= 'project' and kind ~= 'file' and kind ~= 'home' then
    return nil, 'Unknown launch kind: ' .. tostring(kind)
  end
  if kind == 'home' then return { kind = kind, cwd = absolute(vim.fn.expand('~')) } end
  path = absolute(path)
  local stat = path and vim.uv.fs_stat(path)
  if not stat or (kind == 'project' and stat.type ~= 'directory')
      or (kind == 'file' and stat.type ~= 'file') then
    return nil, 'Cannot open ' .. kind .. ': ' .. tostring(path)
  end
  return { kind = kind, cwd = kind == 'project' and path or vim.fs.dirname(path), file = kind == 'file' and path or nil }
end

local function nvim_arguments(context, include_file)
  if context.kind == 'project' then return { '--cmd', 'let g:my_nvim_project_launch = 1' } end
  if context.kind == 'file' and include_file then return { '--', context.file } end
  return {}
end

-- The platform argument exists for command construction tests; launch uses the host OS.
function M.build_launch(kind, path, platform)
  local context, err = launch_context(kind, path)
  if not context then return nil, err end
  local nvim = absolute(vim.v.progpath)
  local argv
  if settings.launcher ~= nil then
    if type(settings.launcher) ~= 'table' or #settings.launcher == 0 then
      return nil, 'project.launcher must be a nonempty argv list'
    end
    argv = {}
    local has_nvim, has_file = false, false
    local substitutions = { ['{nvim}'] = nvim, ['{cwd}'] = context.cwd, ['{kind}'] = kind, ['{file}'] = context.file }
    for _, item in ipairs(settings.launcher) do
      if type(item) ~= 'string' then return nil, 'project.launcher entries must be strings' end
      has_nvim = has_nvim or item == '{nvim}'
      has_file = has_file or item == '{file}'
      if item ~= '{file}' or context.file then
        table.insert(argv, substitutions[item] or item)
      end
    end
    if not has_nvim then return nil, 'project.launcher must contain an exact {nvim} argument' end
    vim.list_extend(argv, nvim_arguments(context, not has_file))
  elseif (platform or (windows and 'windows' or 'macos')) == 'windows' then
    local profile = settings.terminal_profile
    if type(profile) ~= 'string' or profile == '' then return nil, 'project.terminal_profile must be a nonempty string' end
    local executable = vim.fn.exepath('wt.exe')
    argv = { executable ~= '' and executable or 'wt.exe', '--window', 'new', 'new-tab',
      '--profile', profile, '--startingDirectory', context.cwd, '--reloadEnvironment' }
    if context.kind == 'project' then
      -- Keep the project identity even while the embedded shell changes title.
      vim.list_extend(argv, { '--title', project_title(context.cwd), '--suppressApplicationTitle' })
    end
    vim.list_extend(argv, { '--', nvim })
    vim.list_extend(argv, nvim_arguments(context, true))
    -- WT splits semicolons inside argv before parsing, even without a shell.
    -- Its Commandline::AddArg then removes this one escaping backslash.
    for index = 2, #argv do argv[index] = argv[index]:gsub(';', '\\;') end
  else
    argv = { '/usr/bin/osascript', vim.fs.joinpath(root, 'scripts', 'project_launch.applescript'), context.cwd, nvim }
    vim.list_extend(argv, nvim_arguments(context, true))
  end
  return { argv = argv, cwd = context.cwd, env = M.child_env() }
end

local function environment_list(env)
  local list = {}
  for key, value in pairs(env) do list[#list + 1] = key .. '=' .. value end
  table.sort(list)
  return list
end

function M.launch(kind, path)
  local plan, err = M.build_launch(kind, path)
  if not plan then return false, err end
  local args = vim.list_slice(plan.argv, 2)
  local handle
  local ok, result, spawn_error = pcall(function()
    return vim.uv.spawn(plan.argv[1], {
      args = args, cwd = plan.cwd, env = environment_list(plan.env),
      detached = true, hide = false, stdio = { nil, nil, nil },
    }, function(code, signal)
      if handle and not handle:is_closing() then handle:close() end
      if code ~= 0 then
        vim.schedule(function()
          vim.notify(('Could not open Neovim window (exit %s, signal %s). Check the terminal profile/launcher.')
            :format(code, signal), vim.log.levels.ERROR)
        end)
      end
    end)
  end)
  if not ok then return false, tostring(result) end
  handle = result
  if not handle then return false, 'Could not start terminal: ' .. tostring(spawn_error) end
  handle:unref()
  return true
end

local function choose(mode, callback)
  assert(type(callback) == 'function', 'A dialog callback is required')
  local cwd = vim.uv.cwd()
  local argv, env = nil, M.child_env()
  if windows then
    -- Codex and other hosts can inject a PowerShell module path from a different
    -- runtime. The helper uses only built-in commands and .NET/Win32 APIs.
    for key in pairs(env) do if key:upper() == 'PSMODULEPATH' then env[key] = nil end end
    local powershell = vim.fn.exepath('powershell.exe')
    argv = { powershell ~= '' and powershell or 'powershell.exe', '-NoLogo', '-NoProfile', '-STA',
      '-ExecutionPolicy', 'Bypass', '-File', vim.fs.joinpath(root, 'scripts', 'windows_dialog.ps1'),
      '-Mode', mode, '-InitialDirectory', cwd }
  else
    argv = { '/usr/bin/osascript', vim.fs.joinpath(root, 'scripts', 'project_dialog.applescript'), mode, cwd }
  end
  local function finish(path, err)
    vim.schedule(function() callback(path, err) end)
  end
  local ok, err = pcall(vim.system, argv, { text = true, env = env, clear_env = true }, function(result)
    if result.code ~= 0 then
      local message = (result.stderr or ''):gsub('%s+$', '')
      if message == '' then message = ('System dialog failed (exit %d)'):format(result.code) end
      finish(nil, message)
      return
    end
    local path
    if windows then
      local decoded, response = pcall(vim.json.decode, result.stdout or '')
      if not decoded or type(response) ~= 'table' then finish(nil, 'Invalid response from Windows file dialog'); return end
      if response.error then finish(nil, tostring(response.error)); return end
      if response.cancelled then finish(nil, nil); return end
      path = response.path
    else
      -- osascript appends one newline. Preserve whitespace within file names.
      path = (result.stdout or ''):gsub('\r?\n$', '')
      if path == '' then finish(nil, nil); return end
    end
    local stat = type(path) == 'string' and vim.uv.fs_stat(path)
    if not stat or (mode == 'folder' and stat.type ~= 'directory') or (mode == 'file' and stat.type ~= 'file') then
      finish(nil, 'The selected ' .. mode .. ' is unavailable')
      return
    end
    finish(vim.fs.normalize(path), nil)
  end)
  if not ok then finish(nil, tostring(err)) end
end

function M.choose_folder(callback) choose('folder', callback) end
function M.choose_file(callback) choose('file', callback) end

return M