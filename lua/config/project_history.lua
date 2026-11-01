-- One atomic record per canonical folder: independent processes never replace
-- the complete MRU list, including when two projects open simultaneously.
local M = {}
local uv = vim.uv
local state_dir
function M.setup(options)
  state_dir = (options or {}).state_dir or vim.fs.joinpath(vim.fn.stdpath('state'), 'my-nvim')
end
function M.base_dir()
  if not state_dir then M.setup() end
  return state_dir
end
function M.normalize(path)
  assert(type(path) == 'string' and path ~= '', 'Project path is empty')
  if path == '~' then path = vim.fn.expand('~')
  elseif path:sub(1, 2) == '~/' or path:sub(1, 2) == '~\\' then path = vim.fn.expand('~') .. path:sub(2) end
  path = vim.fs.normalize(uv.fs_realpath(path) or vim.fn.fnamemodify(path, ':p'))
  if path ~= '/' and not path:match('^%a:/$') then path = path:gsub('/+$', '') end
  return path
end
function M.key(path)
  path = M.normalize(path)
  return vim.fn.sha256(vim.fn.has('win32') == 1 and path:lower() or path)
end
local function directory() return vim.fs.joinpath(M.base_dir(), 'projects') end
local function record_path(root) return vim.fs.joinpath(directory(), M.key(root) .. '.json') end
local function decode(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return end
  local parsed, value = pcall(vim.json.decode, table.concat(lines, '\n'))
  if parsed and type(value) == 'table' and type(value.root) == 'string'
    and type(value.last_opened) == 'number' then return value end
end
local function changed()
  vim.api.nvim_exec_autocmds('User', { pattern = 'ProjectHistoryChanged', modeline = false })
end
function M.record(root, timestamp)
  root = M.normalize(root)
  assert(vim.fn.isdirectory(root) == 1, 'Project directory does not exist: ' .. root)
  vim.fn.mkdir(directory(), 'p')
  local path = record_path(root)
  local previous = decode(path)
  local seconds, micros = uv.gettimeofday()
  local now = seconds and (seconds + micros / 1000000) or os.time()
  local value = { root = root, name = vim.fs.basename(root),
    last_opened = math.max(timestamp or now, previous and previous.last_opened or 0) }
  local temporary = path .. '.' .. uv.os_getpid() .. '.' .. tostring(uv.hrtime()) .. '.tmp'
  local ok, err = pcall(function()
    vim.fn.writefile({ vim.json.encode(value) }, temporary)
    local renamed, why = uv.fs_rename(temporary, path)
    assert(renamed, why)
  end)
  if not ok then uv.fs_unlink(temporary); error(err) end
  changed()
  return value
end
function M.list()
  local result = {}
  if vim.fn.isdirectory(directory()) == 1 then
    for name, kind in vim.fs.dir(directory()) do
      if kind == 'file' and name:match('^[a-f0-9]+%.json$') then
        local item = decode(vim.fs.joinpath(directory(), name))
        if item then
          local valid, key = pcall(M.key, item.root)
          if valid and name == key .. '.json' then
            item.exists = vim.fn.isdirectory(item.root) == 1
            item.name = vim.fs.basename(item.root)
            result[#result + 1] = item
          end
        end
      end
    end
  end
  table.sort(result, function(a, b)
    if a.last_opened == b.last_opened then return a.root < b.root end
    return a.last_opened > b.last_opened
  end)
  return result
end
function M.remove(root)
  local ok, err = uv.fs_unlink(record_path(root))
  if not ok and err and not err:match('ENOENT') then error(err) end
  changed()
  return ok ~= nil
end
function M.seed()
  local marker = vim.fs.joinpath(M.base_dir(), 'projects-seeded')
  if uv.fs_stat(marker) then return end
  vim.fn.mkdir(M.base_dir(), 'p')
  local excluded = {}
  for _, name in ipairs({ 'cache', 'data', 'state' }) do excluded[#excluded + 1] = M.normalize(vim.fn.stdpath(name)) end
  local seen = {}
  for index, file in ipairs(vim.v.oldfiles or {}) do
    local skip = file:match('^%w+://') ~= nil
    if not skip then
      local normalized = M.normalize(file)
      local compare = vim.fn.has('win32') == 1 and normalized:lower() or normalized
      for _, base in ipairs(excluded) do
        if vim.fn.has('win32') == 1 then base = base:lower() end
        if compare == base or compare:sub(1, #base + 1) == base .. '/' then skip = true; break end
      end
      if not skip and uv.fs_stat(file) then
        local root = vim.fs.root(vim.fs.dirname(file), '.git')
        if root then
          local key = M.key(root)
          if not seen[key] and not uv.fs_stat(record_path(root)) then
            M.record(root, os.time() - index)
          end
          seen[key] = true
        end
      end
    end
  end
  vim.fn.writefile({ '1' }, marker)
end
return M
