-- Reproducible external tools, installed only by scripts/bootstrap.lua.
local M = { roslyn_version = '5.12.0-1.26453.19', jacket_version = '0.30.4' }
local windows = vim.fn.has('win32') == 1
local function exe(name) return windows and (name .. '.exe') or name end
function M.data_dir() return vim.fs.joinpath(vim.fn.stdpath('data'), 'tools') end
function M.executable(machine, key, fallback)
  return machine[key] and vim.fn.expand(machine[key]) or fallback
end
function M.roslyn_command(machine)
  if type(machine.roslyn) == 'table' then return vim.deepcopy(machine.roslyn) end
  local directory = vim.fs.joinpath(M.data_dir(), 'roslyn', M.roslyn_version)
  local path = machine.roslyn
  if not path then
    path = vim.fs.joinpath(directory, exe('roslyn-language-server'))
    -- .NET 10 may install a .cmd shim for the native platform package on Windows.
    -- Launch its real apphost directly, avoiding cmd.exe quoting and PATH issues.
    if windows and vim.fn.executable(path) ~= 1 then
      local apphosts = vim.fn.globpath(directory, '.store/**/roslyn-language-server.exe', false, true)
      if #apphosts == 1 then path = apphosts[1] end
    end
  end
  if path:match('%.dll$') then
    return { M.executable(machine, 'dotnet', 'dotnet'), path, '--stdio' }
  end
  return { path, '--stdio' }
end
local function run(command, options)
  options = vim.tbl_extend('force', { text = true, timeout = 300000 }, options or {})
  print('Running: ' .. table.concat(command, ' '))
  local result = vim.system(command, options):wait()
  assert(result.code == 0, (result.stderr or '') .. '\n' .. (result.stdout or '') .. '\nExit: ' .. tostring(result.code))
  return vim.trim(result.stdout or '')
end
local jacket_hashes = {
  ['windows-x64'] = '8455d2d0612e0a0fe94e033b66c9c083d0c8e341aad9fb5cbdad5124938a9ac9',
  ['windows-arm64'] = 'e51a0f4ebf3ff59a412ecfe21e43ebceb32fa649f17933b0340ec2b51ed18ee2',
  ['macos-arm64'] = '441794c8216d19a90761e21fef7eb6bdd1d21a720707b43bb69f1ca413cf71a5',
  ['macos-x64'] = '4a1837c2092e2e3d195879718603068ae3644ec79089efd193644b61e4c642e9',
}
local function install_jacket(machine)
  local destination = machine.jacket or vim.fs.joinpath(M.data_dir(), 'jacket', M.jacket_version)
  local server = vim.fs.joinpath(destination, exe('jailsp'))
  if vim.fn.executable(server) == 1 and vim.fn.isdirectory(vim.fs.joinpath(destination, 'stdlib')) == 1 then return end
  assert(not machine.jacket, 'local.lua Jacket path must contain jailsp and its matching stdlib: ' .. destination)
  local uname = vim.uv.os_uname()
  local platform = windows and 'windows' or (uname.sysname == 'Darwin' and 'macos' or uname.sysname:lower())
  local arch = (uname.machine == 'arm64' or uname.machine == 'aarch64') and 'arm64' or 'x64'
  local triple = platform .. '-' .. arch
  local expected = assert(jacket_hashes[triple], 'Unsupported Jacket platform: ' .. triple)
  local parent = vim.fs.dirname(destination)
  vim.fn.mkdir(parent, 'p')
  local staging = vim.fs.joinpath(parent, '.install-' .. tostring(vim.uv.os_getpid()))
  assert(not vim.uv.fs_stat(staging), 'Previous staging directory exists: ' .. staging)
  vim.fn.mkdir(staging, 'p')
  local filename = 'jacket-' .. triple .. (windows and '.zip' or '.tar.gz')
  local archive = vim.fs.joinpath(staging, filename)
  run({ 'curl', '--fail', '--location', '--retry', '2', '--silent', '--show-error', '--output', archive,
    'https://github.com/matteopolak/jacket/releases/download/v' .. M.jacket_version .. '/' .. filename })
  local actual
  if windows then
    actual = run({ 'powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
      '$stream=[IO.File]::OpenRead($env:MY_NVIM_ARCHIVE); $sha=[Security.Cryptography.SHA256]::Create(); try { ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace([string][char]45,[string]::Empty).ToLowerInvariant() } finally { $sha.Dispose(); $stream.Dispose() }' },
      { env = { MY_NVIM_ARCHIVE = archive } })
  else
    actual = run({ 'shasum', '-a', '256', archive }):match('^(%x+)')
  end
  assert(actual == expected, 'Jacket archive SHA-256 mismatch: ' .. archive)
  run({ 'tar', '-xf', archive, '-C', staging })
  local source = vim.fs.joinpath(staging, 'jacket-' .. triple)
  assert(vim.fn.executable(vim.fs.joinpath(source, exe('jailsp'))) == 1, 'Jacket archive is missing jailsp')
  assert(not vim.uv.fs_stat(destination), 'Incomplete Jacket toolchain exists; inspect it before retrying: ' .. destination)
  assert(vim.uv.fs_rename(source, destination))
  -- Only remove the unique temporary directory we just created beneath the tool directory.
  assert(vim.fs.dirname(staging) == parent and vim.fs.basename(staging):match('^%.install%-%d+$'))
  vim.fn.delete(staging, 'rf')
end
function M.install()
  local machine = require('config.machine').load()
  local dotnet = M.executable(machine, 'dotnet', 'dotnet')
  assert(vim.fn.executable(dotnet) == 1, '.NET 10 SDK is required')
  local sdks = run({ dotnet, '--list-sdks' })
  assert(sdks:match('^10%.') or sdks:match('\n10%.'), '.NET 10 SDK is required')
  local command = M.roslyn_command(machine)
  local roslyn_exists
  if type(machine.roslyn) == 'string' and machine.roslyn:match('%.dll$') then
    roslyn_exists = vim.uv.fs_stat(machine.roslyn) ~= nil
  else
    roslyn_exists = vim.fn.executable(command[1]) == 1
  end
  if not roslyn_exists then
    assert(not machine.roslyn, 'Configured Roslyn command is not installed')
    local directory = vim.fs.joinpath(M.data_dir(), 'roslyn', M.roslyn_version)
    vim.fn.mkdir(directory, 'p')
    run({ dotnet, 'tool', 'install', '--tool-path', directory, 'roslyn-language-server', '--version', M.roslyn_version,
      '--source', 'https://pkgs.dev.azure.com/azure-public/vside/_packaging/vs-impl/nuget/v3/index.json' },
      { env = { DOTNET_CLI_TELEMETRY_OPTOUT = '1', DOTNET_NOLOGO = '1' } })
  end
  install_jacket(machine)
end
return M
