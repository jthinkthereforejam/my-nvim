-- Minimal installer bridge. No plugin loading, downloads, or configuration linking.
-- nvim --clean -l scripts/environment.lua json [output-file]
-- nvim --clean -l scripts/environment.lua sh > private-temporary-file
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(_G.arg[0])))
vim.g.my_nvim_root = root
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
local machine_module = require('config.machine')
local machine = machine_module.load()
machine_module.apply(machine)
local tools = require('config.tools')
local result = {
  environment = { PATH = vim.env.PATH, HTTP_PROXY = vim.env.HTTP_PROXY, HTTPS_PROXY = vim.env.HTTPS_PROXY },
  tools = {
    dotnet = tools.executable(machine, 'dotnet', 'dotnet'),
    clangd = tools.executable(machine, 'clangd', 'clangd'),
    rust_analyzer = tools.executable(machine, 'rust_analyzer', 'rust-analyzer'),
  },
}
for key, value in pairs(result.tools) do
  assert(type(value) == 'string' and not value:find('\0', 1, true), 'Invalid local.lua tool path: ' .. key)
end
local format = _G.arg[1] or 'json'
local output
if format == 'json' then
  output = vim.json.encode(result) .. '\n'
elseif format == 'sh' then
  local function quote(value)
    assert(not value:find('\0', 1, true), 'Environment values cannot contain NUL')
    return "'" .. value:gsub("'", "'\\''") .. "'"
  end
  local lines = {}
  for _, name in ipairs({ 'PATH', 'HTTP_PROXY', 'HTTPS_PROXY' }) do
    local value = result.environment[name]
    if value then lines[#lines + 1] = 'export ' .. name .. '=' .. quote(value) end
  end
  for _, item in ipairs({ { 'MY_NVIM_DOTNET', 'dotnet' }, { 'MY_NVIM_CLANGD', 'clangd' }, { 'MY_NVIM_RUST_ANALYZER', 'rust_analyzer' } }) do
    lines[#lines + 1] = item[1] .. '=' .. quote(result.tools[item[2]])
  end
  output = table.concat(lines, '\n') .. '\n'
else
  error('Unknown environment output format: ' .. tostring(format))
end
if _G.arg[2] then
  local file = assert(io.open(_G.arg[2], 'wb'))
  assert(file:write(output))
  assert(file:close())
else
  io.write(output)
end
