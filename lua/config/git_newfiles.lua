-- Gitsigns v2.1 cannot attach HEAD-missing paths. Cover only those paths with
-- native signs; never synthesize an index entry or write any Git object.
local M = {}
local api, uv = vim.api, vim.uv
local ns = api.nvim_create_namespace('my-nvim-git-newfiles')
local buffers, repositories, enabled, exiting = {}, {}, true, false
local function normal(buf)
  return api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == '' and api.nvim_buf_get_name(buf) ~= ''
    and not api.nvim_buf_get_name(buf):match('^%a[%w+.-]*://')
    and vim.fn.isdirectory(api.nvim_buf_get_name(buf)) == 0
end
local function clear(buf)
  if api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf) then api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
end
local function render(buf)
  clear(buf)
  local entry = buffers[buf]
  if not enabled or not entry or not entry.eligible or not normal(buf) then return end
  local count = api.nvim_buf_line_count(buf)
  if count > 40000 then return end -- Match Gitsigns' default file-length limit.
  if count == 1 and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == '' then return end
  for row = 0, count - 1 do
    api.nvim_buf_set_extmark(buf, ns, row, 0, { sign_text = '+', sign_hl_group = 'GitSignsAdd', priority = 6 })
  end
end
local function stop_repository(repo)
  for _, handle in pairs(repo.watchers) do
    pcall(handle.stop, handle)
    if not handle:is_closing() then handle:close() end
  end
  repositories[repo.key] = nil
end
local function leave_repository(buf, entry)
  local repo = entry and entry.repo
  if not repo then return end
  repo.buffers[buf] = nil
  entry.repo = nil
  if not next(repo.buffers) then stop_repository(repo) end
end
local function alive(buf, entry, generation)
  return not exiting and buffers[buf] == entry and entry.generation == generation
    and normal(buf) and api.nvim_buf_get_name(buf) == entry.name
end
local function command(buf, entry, generation, cwd, args, callback)
  if not alive(buf, entry, generation) then return end
  local argv = { 'git', '-C', cwd }
  vim.list_extend(argv, args)
  local ok, job = pcall(vim.system, argv, { text = true, timeout = 3000 }, vim.schedule_wrap(function(result)
    if not alive(buf, entry, generation) then return end
    entry.job = nil
    callback(result)
  end))
  if ok then entry.job = job else callback({ code = -1, stdout = '' }) end
end
local function watch_repository(root, gitdir, buf, entry)
  local key = vim.fn.has('win32') == 1 and root:lower() or root
  local repo = repositories[key]
  if not repo then
    repo = { key = key, root = root, gitdir = gitdir, buffers = {}, watchers = {}, generation = 0 }
    repositories[key] = repo
  end
  if entry.repo ~= repo then leave_repository(buf, entry) end
  entry.repo, repo.buffers[buf] = repo, true
  local function changed()
    if exiting or repositories[key] ~= repo then return end
    repo.generation = repo.generation + 1
    local generation = repo.generation
    vim.defer_fn(function()
      if exiting or repositories[key] ~= repo or repo.generation ~= generation then return end
      for target in pairs(repo.buffers) do M.refresh(target) end
    end, 100)
  end
  local function watch(path)
    if repo.watchers[path] or not uv.fs_stat(path) then return end
    local handle = uv.new_fs_event()
    if not handle then return end
    local ok, result = pcall(handle.start, handle, path, {}, vim.schedule_wrap(changed))
    if ok and result then repo.watchers[path] = handle else handle:close() end
  end
  local common = gitdir
  local commondir = vim.fs.joinpath(gitdir, 'commondir')
  if vim.fn.filereadable(commondir) == 1 then
    local ok, lines = pcall(vim.fn.readfile, commondir)
    if ok and lines[1] then common = vim.fs.normalize(vim.fs.joinpath(gitdir, lines[1])) end
  end
  watch(gitdir); watch(common)
  -- Directory watches catch atomic ref replacement, including nested branch
  -- names. This is one shared watcher set per repository, not a buffer poller.
  local pending = { vim.fs.joinpath(common, 'refs'), vim.fs.joinpath(common, 'reftable') }
  local visited = 0
  while #pending > 0 and visited < 256 do
    local path = table.remove(pending)
    watch(path)
    local scan = uv.fs_scandir(path)
    if scan then
      while true do
        local name, kind = uv.fs_scandir_next(scan)
        if not name then break end
        if kind == 'directory' then pending[#pending + 1] = vim.fs.joinpath(path, name) end
      end
    end
    visited = visited + 1
  end
end
local function classify(buf, entry, generation)
  local directory = vim.fs.dirname(entry.name)
  command(buf, entry, generation, directory, { 'rev-parse', '--show-toplevel', '--absolute-git-dir' }, function(repo_result)
    if repo_result.code ~= 0 then entry.eligible = false; leave_repository(buf, entry); clear(buf); return end
    local paths = vim.split(vim.trim(repo_result.stdout or ''), '\n', { plain = true })
    local root, gitdir = vim.fs.normalize(paths[1]), paths[2] and vim.fs.normalize(paths[2])
    if not gitdir then entry.eligible = false; clear(buf); return end
    local target = vim.fs.normalize(entry.name)
    if vim.fn.has('win32') == 1 then
      root = vim.fs.normalize(uv.fs_realpath(root) or root)
      target = vim.fs.normalize(uv.fs_realpath(entry.name)
        or vim.fs.joinpath(uv.fs_realpath(directory) or directory, vim.fs.basename(entry.name)))
    end
    local relative = vim.fs.relpath(root, target)
    if not relative then entry.eligible = false; leave_repository(buf, entry); clear(buf); return end
    relative = relative:gsub('\\', '/')
    command(buf, entry, generation, root,
      { '--literal-pathspecs', 'ls-files', '--stage', '--others', '--exclude-standard', '-z', '--', relative }, function(listed)
      if listed.code ~= 0 or listed.stdout == '' then
        entry.eligible = false; leave_repository(buf, entry); clear(buf); return
      end
      command(buf, entry, generation, root, { 'rev-parse', '--verify', '--quiet', 'HEAD' }, function(head)
        local function missing()
          entry.eligible = true
          watch_repository(root, gitdir, buf, entry)
          render(buf)
        end
        if head.code == 1 then missing(); return end
        if head.code ~= 0 then entry.eligible = false; leave_repository(buf, entry); clear(buf); return end
        local revision = vim.trim(head.stdout)
        command(buf, entry, generation, root, { '--literal-pathspecs', 'ls-tree', '-z', revision, '--', relative }, function(tree)
          if tree.code ~= 0 then entry.eligible = false; leave_repository(buf, entry); clear(buf); return end
          if tree.stdout == '' then missing(); return end
          local was_new = entry.eligible
          entry.eligible = false
          leave_repository(buf, entry)
          clear(buf)
          if was_new then require('gitsigns').attach(buf) end
        end)
      end)
    end)
  end)
end
function M.refresh(buf)
  buf = buf or api.nvim_get_current_buf()
  if buf == 0 then buf = api.nvim_get_current_buf() end
  local entry = buffers[buf]
  if not normal(buf) or vim.fn.executable('git') ~= 1 then
    clear(buf)
    if entry then leave_repository(buf, entry); buffers[buf] = nil end
    return
  end
  if not entry then entry = { generation = 0 }; buffers[buf] = entry end
  if entry.job then pcall(entry.job.kill, entry.job, 15); entry.job = nil end
  entry.generation = entry.generation + 1
  local generation, name = entry.generation, api.nvim_buf_get_name(buf)
  if entry.name ~= name then entry.eligible = false; leave_repository(buf, entry); clear(buf) end
  entry.name = name
  vim.defer_fn(function() if alive(buf, entry, generation) then classify(buf, entry, generation) end end, 100)
end
function M.redraw(value)
  if value ~= nil then enabled = value end
  for buf in pairs(buffers) do render(buf) end
end
function M.preview()
  local buf, entry = api.nvim_get_current_buf(), buffers[api.nvim_get_current_buf()]
  if not entry or not entry.eligible or not normal(buf) then return false end
  local source, lines = api.nvim_buf_get_lines(buf, 0, -1, false), {}
  lines[1] = ('@@ -0,0 +1,%d @@'):format(#source)
  for _, line in ipairs(source) do lines[#lines + 1] = '+' .. line end
  vim.lsp.util.open_floating_preview(lines, 'diff', { border = 'rounded', focus_id = 'my-nvim-git-newfiles',
    max_height = math.max(1, math.floor(vim.o.lines * 0.5)), max_width = math.max(1, vim.o.columns - 8) })
  return true
end
function M.navigate(direction)
  local buf, entry = api.nvim_get_current_buf(), buffers[api.nvim_get_current_buf()]
  if not entry or not entry.eligible or not normal(buf) then return false end
  local row = api.nvim_win_get_cursor(0)[1]
  -- A new file is one added hunk. Match native hunk navigation/wrap semantics.
  if direction == 'next' or direction == 'prev' then
    if row ~= 1 or vim.o.wrapscan then api.nvim_win_set_cursor(0, { 1, 0 }) end
  end
  return true
end
function M.setup()
  exiting = false
  local group = api.nvim_create_augroup('my-nvim-git-newfiles', { clear = true })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile', 'BufFilePost', 'BufWritePost', 'BufEnter' }, {
    group = group, callback = function(event) M.refresh(event.buf) end,
  })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { group = group, callback = function(event)
    local entry = buffers[event.buf]
    if not entry or not entry.eligible then return end
    entry.render_generation = (entry.render_generation or 0) + 1
    local generation = entry.render_generation
    vim.defer_fn(function()
      if buffers[event.buf] == entry and entry.render_generation == generation then render(event.buf) end
    end, 100)
  end })
  api.nvim_create_autocmd('FocusGained', { group = group, callback = function()
    for buf in pairs(buffers) do M.refresh(buf) end
  end })
  api.nvim_create_autocmd('User', { group = group, pattern = 'GitSignsUpdate', callback = function(event)
    local buf = event.data and event.data.buffer
    if buf and buffers[buf] and buffers[buf].eligible then M.refresh(buf) end
  end })
  api.nvim_create_autocmd('BufWipeout', { group = group, callback = function(event)
    local entry = buffers[event.buf]
    if entry then
      entry.generation = entry.generation + 1
      if entry.job then pcall(entry.job.kill, entry.job, 15) end
      leave_repository(event.buf, entry)
      buffers[event.buf] = nil
    end
  end })
  api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function()
    exiting = true
    for _, repo in pairs(repositories) do stop_repository(repo) end
    for _, entry in pairs(buffers) do if entry.job then pcall(entry.job.kill, entry.job, 15) end end
  end })
  for _, buf in ipairs(api.nvim_list_bufs()) do M.refresh(buf) end
end
return M
