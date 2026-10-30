local M = {}
local cached
function M.load()
  if cached then return cached end
  local path = vim.fs.joinpath(vim.g.my_nvim_root or vim.fn.stdpath('config'), 'local.lua')
  cached = vim.uv.fs_stat(path) and dofile(path) or {}
  assert(type(cached) == 'table', 'local.lua must return a table')
  return cached
end
function M.apply(machine)
  local separator = vim.fn.has('win32') == 1 and ';' or ':'
  local directories = { vim.fs.dirname(vim.v.progpath) }
  for _, path in ipairs(machine.path or {}) do table.insert(directories, vim.fs.normalize(vim.fn.expand(path))) end
  vim.env.PATH = table.concat(directories, separator) .. separator .. (vim.env.PATH or '')
  -- An optional local proxy is inherited by git, curl, and dotnet, only in this process.
  if machine.proxy and machine.proxy ~= '' then
    vim.env.HTTPS_PROXY = machine.proxy
    vim.env.HTTP_PROXY = machine.proxy
  end
end
return M
