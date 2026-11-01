-- Save real file buffers after editing has settled outside Insert/Replace mode.
-- Every buffer owns its timer and disk baseline. Writes use the normal editor
-- path, preserving BufWritePre/Post and LSP notifications without formatting.
local M = {}
local api, uv = vim.api, vim.uv
local records = {}
local config = { enabled = true, delay_ms = 1000 }
local write_depth = 0
local arm, changed

local function exiting()
  return vim.v.exiting ~= nil and vim.v.exiting ~= vim.NIL
end
local function cancel(record)
  record.generation = (record.generation or 0) + 1
  local timer = record.timer
  record.timer = nil
  if timer and not timer:is_closing() then timer:stop(); timer:close() end
end
local function filename(buf)
  if not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= '' then return nil end
  local name = api.nvim_buf_get_name(buf)
  if name == '' or name:match('^%a[%w+.-]*://') then return nil end
  -- Keep the logical name: resolving a symlink here would hide a later change
  -- to its target from the conflict check.
  return vim.fs.normalize(name)
end
local function fingerprint(path)
  local stat, err = uv.fs_stat(path)
  if not stat then
    if tostring(err):find('ENOENT', 1, true) then return { exists = false } end
    return nil, 'Cannot inspect the file on disk.'
  end
  return { exists = true, type = stat.type, dev = stat.dev, ino = stat.ino, size = stat.size,
    mtime = stat.mtime, ctime = stat.ctime }
end
local function eligible(buf)
  return filename(buf) ~= nil and vim.bo[buf].modifiable and not vim.bo[buf].readonly and vim.bo[buf].modified
end
local function insert_mode()
  local mode = api.nvim_get_mode().mode
  return mode:match('^i') or mode:match('^R') or mode:match('^ni[IRV]')
end
local function editing(buf)
  return api.nvim_get_current_buf() == buf and not not insert_mode()
end
local function menu_visible(buf)
  if api.nvim_get_current_buf() ~= buf then return false end
  if vim.fn.pumvisible() == 1 then return true end
  local cmp = package.loaded['blink.cmp']
  return cmp and cmp.is_menu_visible and cmp.is_menu_visible() or false
end
local function blocked(buf)
  if api.nvim_get_current_buf() ~= buf then return false end
  -- Do not interrupt operators, visual selections, command lines or input prompts.
  -- A hidden file can still be saved while a different buffer is being edited.
  return api.nvim_get_mode().mode ~= 'n' or menu_visible(buf)
end
local function warn(record)
  local now = uv.now()
  if now - (record.last_notice or -math.huge) >= 30000 then
    record.last_notice = now
    -- Background errors must not open a hit-enter prompt or interrupt a shell.
    -- Keep the notice on one screen line; the full reason remains in status().
    local name = vim.fs.basename(record.name):gsub('%c', '?')
    while vim.fn.strdisplaywidth(name) > 24 do name = vim.fn.strcharpart(name, 0, vim.fn.strchars(name) - 1) end
    local message = ('AutoSave paused: %s; :AutoSaveStatus'):format(name)
    while vim.fn.strdisplaywidth(message) > math.max(1, vim.o.columns - 2) do
      message = vim.fn.strcharpart(message, 0, vim.fn.strchars(message) - 1)
    end
    vim.notify(message, vim.log.levels.WARN)
  end
end
local function pause(record, reason)
  cancel(record)
  record.paused, record.waiting = reason, false
  warn(record)
end
local function observe(buf, reset)
  local name = filename(buf)
  if not name then return nil end
  local record = records[buf]
  if not record then
    record = { buf = buf, generation = 0 }
    records[buf] = record
  end
  if record.name ~= name or reset then
    cancel(record)
    record.name = name
    record.baseline, record.baseline_error = fingerprint(name)
    record.paused, record.waiting = nil, false
  end
  if not record.attached then
    record.attached = api.nvim_buf_attach(buf, false, {
      on_lines = function()
        if records[buf] ~= record then return true end
        if exiting() then return end
        -- Lua/LSP edits to a hidden buffer do not always emit TextChanged. This
        -- callback only queues work; never write while its textlock is active.
        cancel(record)
        if record.queued then return end
        record.queued = true
        vim.schedule(function()
          record.queued = false
          if records[buf] == record then changed(buf) end
        end)
      end,
      on_detach = function()
        if records[buf] == record then cancel(record); records[buf] = nil end
      end,
    })
  end
  return record
end
local function save(record)
  local buf = record.buf
  if not config.enabled or exiting() or records[buf] ~= record or record.paused or not eligible(buf) then return end
  if editing(buf) or blocked(buf) then record.waiting = true; return end
  if filename(buf) ~= record.name then changed(buf); return end
  local disk, stat_error = fingerprint(record.name)
  if not disk or not record.baseline then pause(record, stat_error or record.baseline_error or 'No safe disk baseline.'); return end
  if disk.exists and disk.type ~= 'file' then pause(record, 'The path is not a regular file.'); return end
  if not vim.deep_equal(disk, record.baseline) then
    pause(record, 'The file changed, was replaced or was deleted externally. Save or reload it manually to resume.')
    return
  end
  if not disk.exists then
    local parent = uv.fs_stat(vim.fs.dirname(record.name))
    if not parent or parent.type ~= 'directory' then pause(record, 'The parent directory does not exist.'); return end
  end
  local tick = api.nvim_buf_get_changedtick(buf)
  write_depth = write_depth + 1
  local ok = pcall(api.nvim_buf_call, buf, function()
    -- No bang, no noautocmd and no direct filesystem writes. Silent only hides
    -- the repeated successful-write message; native save hooks still execute.
    vim.cmd.update({ mods = { silent = true } })
  end)
  write_depth = write_depth - 1
  if records[buf] ~= record or not api.nvim_buf_is_valid(buf) then return end
  if not ok then pause(record, 'Writing failed. Save manually after resolving the error to resume.'); return end
  if vim.bo[buf].modified then
    if api.nvim_buf_get_changedtick(buf) == tick then pause(record, 'The write did not finish. Save manually to resume.')
    else arm(buf) end
  end
end
arm = function(buf, leaving)
  local record = observe(buf)
  if not record then return end
  cancel(record)
  record.waiting = false
  if not config.enabled or exiting() or write_depth > 0 or record.paused or not eligible(buf) then return end
  if not leaving and editing(buf) then record.waiting = true; return end
  local generation, tick = record.generation, api.nvim_buf_get_changedtick(buf)
  record.timer = vim.defer_fn(function()
    -- A cancelled callback may already be queued. It must not clear a newer timer.
    if records[buf] ~= record or record.generation ~= generation then return end
    record.timer = nil
    if not config.enabled or exiting() then return end
    if not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then return end
    if api.nvim_buf_get_changedtick(buf) ~= tick then arm(buf); return end
    save(record)
  end, config.delay_ms)
end
changed = function(buf)
  if write_depth == 0 then arm(buf) end
end
function M.status(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local pending, paused = 0, 0
  for _, record in pairs(records) do
    if record.timer then pending = pending + 1 end
    if record.paused then paused = paused + 1 end
  end
  local record = records[buf]
  return { enabled = config.enabled, delay_ms = config.delay_ms, pending_count = pending, paused_count = paused,
    buffer = { pending = record ~= nil and record.timer ~= nil, paused = record ~= nil and record.paused ~= nil,
      waiting = record ~= nil and not not record.waiting, reason = record and record.paused or nil } }
end
function M.toggle()
  config.enabled = not config.enabled
  for _, record in pairs(records) do cancel(record) end
  if config.enabled then
    for _, buf in ipairs(api.nvim_list_bufs()) do if eligible(buf) then arm(buf) end end
  end
  vim.notify('AutoSave: ' .. (config.enabled and 'enabled' or 'disabled'), vim.log.levels.INFO)
  return config.enabled
end
function M.setup(machine)
  local value = (machine or {}).autosave
  local options = type(value) == 'table' and value or {}
  for _, record in pairs(records) do cancel(record) end
  config.enabled = value ~= false and options.enabled ~= false
  config.delay_ms = options.delay_ms or 1000
  if type(config.delay_ms) ~= 'number' or config.delay_ms < 1 or config.delay_ms % 1 ~= 0 then
    config.enabled, config.delay_ms = false, 1000
    vim.notify('AutoSave disabled: delay_ms must be a positive integer.', vim.log.levels.WARN)
  end
  local group = api.nvim_create_augroup('my-nvim-autosave', { clear = true })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
    group = group, callback = function(args) observe(args.buf, true) end,
  })
  api.nvim_create_autocmd('BufFilePost', {
    group = group, callback = function(args)
      local old = records[args.buf]
      local old_name = old and old.name
      local record = observe(args.buf)
      if record and record.name ~= old_name and record.baseline and record.baseline.exists then
        pause(record, 'The buffer was renamed to an existing path. Save or reload it manually to resume.')
      elseif record and eligible(args.buf) then arm(args.buf) end
    end,
  })
  api.nvim_create_autocmd('BufWritePost', {
    group = group, callback = function(args)
      local record = observe(args.buf, true)
      if record and write_depth == 0 and eligible(args.buf) then arm(args.buf) end
    end,
  })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
    group = group, callback = function(args) changed(args.buf) end,
  })
  api.nvim_create_autocmd('InsertEnter', {
    group = group, callback = function(args)
      if write_depth > 0 then return end
      local record = observe(args.buf)
      if record then cancel(record); record.waiting = eligible(args.buf) end
    end,
  })
  api.nvim_create_autocmd({ 'InsertLeave', 'BufLeave' }, {
    group = group, callback = function(args)
      if write_depth == 0 then arm(args.buf, true) end
    end,
  })
  api.nvim_create_autocmd({ 'BufEnter', 'ModeChanged', 'CmdlineLeave', 'CompleteDone' }, {
    group = group, callback = function()
      if write_depth > 0 then return end
      local buf = api.nvim_get_current_buf()
      local record = observe(buf)
      if record and (record.waiting or (not record.timer and eligible(buf))) then arm(buf) end
    end,
  })
  api.nvim_create_autocmd('User', {
    group = group, pattern = { 'BlinkCmpHide', 'BlinkCmpAccept' }, callback = function()
      if write_depth > 0 then return end
      for buf, record in pairs(records) do if record.waiting then arm(buf) end end
    end,
  })
  api.nvim_create_autocmd({ 'BufUnload', 'BufDelete', 'BufWipeout' }, {
    group = group, callback = function(args)
      local record = records[args.buf]
      if record then cancel(record); records[args.buf] = nil end
    end,
  })
  api.nvim_create_autocmd('VimLeavePre', {
    group = group, callback = function() for _, record in pairs(records) do cancel(record) end end,
  })
  api.nvim_create_user_command('AutoSaveToggle', M.toggle,
    { desc = 'Toggle delayed automatic saving for this instance', force = true })
  api.nvim_create_user_command('AutoSaveStatus', function()
    local status = M.status()
    vim.notify(('AutoSave: %s; delay %d ms; pending %d; paused %d%s'):format(
      status.enabled and 'enabled' or 'disabled', status.delay_ms, status.pending_count, status.paused_count,
      status.buffer.reason and '; ' .. status.buffer.reason or ''), vim.log.levels.INFO)
  end, { desc = 'Show delayed automatic saving state', force = true })
  for _, buf in ipairs(api.nvim_list_bufs()) do
    observe(buf)
    if eligible(buf) then arm(buf) end
  end
end
return M
