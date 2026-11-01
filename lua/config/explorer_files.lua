-- File operations for the pinned Snacks explorer. Never replace a live buffer
-- with a newly opened one: filenames change, while buffer identity and undo stay.
local M = { actions = {} }
local api, uv, fn = vim.api, vim.uv, vim.fn
local windows = fn.has('win32') == 1
local function normalize(path)
  assert(type(path) == 'string' and not path:match('^%s*$') and not path:find('%z'), 'A non-empty path is required.')
  path = vim.fs.normalize(fn.fnamemodify(path, ':p'), { expand_env = false })
  if path ~= '/' and not path:match('^%a:/$') then path = path:gsub('/+$', '') end
  return path
end
local function key(path) return windows and path:lower() or path end
local function within(path, parent)
  path, parent = key(path), key(parent)
  return path == parent or path:sub(1, #parent + 1) == parent .. '/'
end
local function real(path) return normalize(uv.fs_realpath(path) or path) end
local function protected(path)
  for part in path:gmatch('[^/]+') do if key(part) == '.git' then return true end end
  return false
end
local function source_allowed(path)
  local root = real(require('config.search').project_root())
  if within(root, real(path)) then return false, 'The project root and its parents cannot be renamed, moved or deleted.' end
  if protected(path) or protected(real(path)) then return false, 'The .git directory is protected.' end
  return true
end
local function target_allowed(path)
  local root = real(require('config.search').project_root())
  if key(real(path)) == key(root) or protected(path) or protected(real(path)) then
    return false, 'The project root and .git directory are protected.'
  end
  return true
end
local function exists(path) return uv.fs_lstat(path) ~= nil end
local function affected(path, directory)
  local result = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(buf)
    if name ~= '' and not name:match('^%a[%w+.-]*://') and vim.bo[buf].buftype == '' then
      name = normalize(name)
      if key(name) == key(path) or (directory and within(name, path)) then result[#result + 1] = { buf = buf, from = name } end
    end
  end
  return result
end
local function changes_for(from, to, directory)
  local changes = affected(from, directory)
  for _, change in ipairs(changes) do change.to = to .. change.from:sub(#from + 1) end
  return changes
end
local function target_buffers(changes, destination, directory)
  local moving = {}; for _, change in ipairs(changes) do moving[change.buf] = true end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if not moving[buf] then
      local name = api.nvim_buf_get_name(buf)
      if name ~= '' and not name:match('^%a[%w+.-]*://') then
        name = normalize(name)
        if destination and (key(name) == key(destination) or (directory and within(name, destination))) then
          return false, 'A buffer already uses the destination name.'
        end
        for _, change in ipairs(changes) do
          if key(name) == key(change.to) then return false, 'A buffer already uses the destination name.' end
        end
      end
    end
  end
  return true
end
local function validate_rename(from, to)
  local allowed, why = source_allowed(from); if not allowed then return nil, why end
  allowed, why = target_allowed(to); if not allowed then return nil, why end
  local stat = uv.fs_lstat(from)
  if not stat then return nil, 'The source does not exist.' end
  if stat.type ~= 'file' and stat.type ~= 'directory' and stat.type ~= 'link' then return nil, 'This file type cannot be renamed.' end
  if from == to then return nil, 'The destination is unchanged.' end
  local case_only = windows and key(from) == key(to)
  local directory = stat.type == 'directory' or (stat.type == 'link' and fn.isdirectory(from) == 1)
  if exists(to) and not case_only then return nil, 'The destination already exists; nothing was overwritten.' end
  if directory and within(to, from) and not case_only then return nil, 'A directory cannot be moved inside itself.' end
  local changes = changes_for(from, to, directory)
  allowed, why = target_buffers(changes, to, directory); if not allowed then return nil, why end
  return { from = from, to = to, directory = directory, changes = changes, case_only = case_only }
end
local function ensure_parent(path)
  local parent = vim.fs.dirname(path)
  if fn.isdirectory(parent) ~= 1 then fn.mkdir(parent, 'p') end
  assert(fn.isdirectory(parent) == 1, 'The destination parent could not be created.')
end
local function move_disk(from, to, case_only)
  if not case_only then
    assert(not exists(to), 'The destination already exists; nothing was overwritten.')
    assert(uv.fs_rename(from, to))
    return
  end
  -- Windows does not consistently update casing in a direct same-name rename.
  local temporary = from .. '.my-nvim-rename-' .. uv.os_getpid() .. '-' .. uv.hrtime()
  assert(not exists(temporary), 'The temporary rename path already exists.')
  assert(uv.fs_rename(from, temporary))
  local ok, err = uv.fs_rename(temporary, to)
  if not ok then uv.fs_rename(temporary, from); error(err) end
end
local buffer_options = { 'binary', 'fileformat', 'fileencoding', 'bomb', 'endofline', 'fixendofline',
  'filetype', 'readonly', 'modifiable', 'buflisted', 'undofile', 'undolevels', 'bufhidden', 'swapfile' }
local function snapshot_buffer(buf)
  local snapshot = { buf = buf, lines = api.nvim_buf_get_lines(buf, 0, -1, true), modified = vim.bo[buf].modified, options = {}, views = {} }
  for _, option in ipairs(buffer_options) do snapshot.options[option] = api.nvim_get_option_value(option, { buf = buf }) end
  for _, win in ipairs(fn.win_findbuf(buf)) do snapshot.views[win] = api.nvim_win_call(win, fn.winsaveview) end
  local ok, err = pcall(api.nvim_buf_call, buf, function()
    if #fn.undotree().entries > 0 then
      snapshot.undo = fn.tempname()
      vim.cmd.wundo({ args = { snapshot.undo }, bang = true, mods = { silent = true } })
      assert(exists(snapshot.undo), 'The undo snapshot could not be written.')
    end
  end)
  if not ok then if snapshot.undo then fn.delete(snapshot.undo) end; error(err) end
  snapshot.clients = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if client.id and vim.lsp.buf_is_attached(buf, client.id) then snapshot.clients[#snapshot.clients + 1] = client.id end
  end
  return snapshot
end
local function detach_clients(snapshot)
  for _, id in ipairs(snapshot.clients) do vim.lsp.buf_detach_client(snapshot.buf, id) end
end
local function attach_clients(snapshot)
  for _, id in ipairs(snapshot.clients) do
    local client = vim.lsp.get_client_by_id(id)
    if client and not client:is_stopped() then assert(vim.lsp.buf_attach_client(snapshot.buf, id), 'The renamed buffer could not reattach its LSP client.') end
  end
end
local function restore_buffer(snapshot, reread)
  local buf = snapshot.buf
  if not api.nvim_buf_is_valid(buf) then error('A renamed buffer was deleted by another callback.') end
  local visible, scratch = fn.win_findbuf(buf), nil
  if reread then
    scratch = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'hide'
    -- A real unload invokes native on_detach (unlike an on_lines return value),
    -- clearing the old LSP URI closures. Replace buffers only; never close wins.
    for _, win in ipairs(visible) do vim.cmd('noautocmd lua vim.api.nvim_win_set_buf(' .. win .. ',' .. scratch .. ')') end
  end
  local ok, err = xpcall(function()
    if reread then vim.cmd('noautocmd lua vim.api.nvim_buf_delete(' .. buf .. ',{force=true,unload=true})') end
    api.nvim_buf_call(buf, function()
      -- A plain name change sets [Not edited]. Reloading the moved file resets
      -- that flag without writing; restoring the old undo snapshot is lossless.
      if reread then vim.cmd('silent noautocmd keepalt keepjumps edit!') end
      vim.bo[buf].modifiable = true
      if not vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, true), snapshot.lines) then
        api.nvim_buf_set_lines(buf, 0, -1, true, snapshot.lines)
      end
      if snapshot.undo then vim.cmd.rundo({ args = { snapshot.undo }, mods = { silent = true } })
      else
        vim.bo[buf].undolevels = -1
        api.nvim_buf_set_lines(buf, 0, 1, true, { snapshot.lines[1] or '' })
      end
      for _, option in ipairs(buffer_options) do
        if option ~= 'bufhidden' then api.nvim_set_option_value(option, snapshot.options[option], { buf = buf }) end
      end
      vim.bo[buf].modified = snapshot.modified
    end)
  end, debug.traceback)
  -- Keep wipe/close-on-hide buffers protected until every real window is back.
  for _, win in ipairs(visible) do
    if api.nvim_win_is_valid(win) and api.nvim_buf_is_valid(buf) then
      pcall(vim.cmd, 'noautocmd lua vim.api.nvim_win_set_buf(' .. win .. ',' .. buf .. ')')
    end
  end
  if api.nvim_buf_is_valid(buf) then vim.bo[buf].bufhidden = snapshot.options.bufhidden end
  if scratch and api.nvim_buf_is_valid(scratch) then pcall(api.nvim_buf_delete, scratch, { force = true }) end
  for win, view in pairs(snapshot.views) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then api.nvim_win_call(win, function() fn.winrestview(view) end) end
  end
  if not ok then error(err, 0) end
end
local function relevant_clients(from, to)
  local result = {}
  for _, client in ipairs(vim.lsp.get_clients()) do
    local roots = {}
    for _, folder in ipairs(client.workspace_folders or {}) do roots[#roots + 1] = vim.uri_to_fname(folder.uri) end
    if client.config and type(client.config.root_dir) == 'string' then roots[#roots + 1] = client.config.root_dir end
    local relevant = #roots == 0
    for _, root in ipairs(roots) do if within(from, normalize(root)) or within(to, normalize(root)) then relevant = true end end
    if relevant then result[#result + 1] = client end
  end
  return result
end
local function prepare_lsp(clients, params)
  local edits = {}
  for _, client in ipairs(clients) do
    if client:supports_method('workspace/willRenameFiles') then
      local response, err = client:request_sync('workspace/willRenameFiles', params, 1000, 0)
      assert(response and not response.err and not err, ('%s did not finish willRenameFiles; rename cancelled.'):format(client.name))
      local edit = response.result
      if edit and edit ~= vim.NIL then
        -- Resource operations could overwrite/delete other files through the
        -- generic LSP handler. Refuse those; ordinary text edits are preserved.
        for _, change in ipairs(edit.documentChanges or {}) do assert(not change.kind, 'willRenameFiles returned an unsupported filesystem operation.') end
        edits[#edits + 1] = { edit = edit, encoding = client.offset_encoding }
      end
    end
  end
  for _, item in ipairs(edits) do vim.lsp.util.apply_workspace_edit(item.edit, item.encoding) end
end
function M.rename_path(from, to)
  local normalized, paths = pcall(function() return { normalize(from), normalize(to) } end)
  if not normalized then return false, tostring(paths) end
  from, to = paths[1], paths[2]
  local valid, plan, why = pcall(validate_rename, from, to)
  if not valid then return false, tostring(plan) end
  if not plan then return false, why end
  local autosave = require('config.autosave')
  local token, err = autosave.begin_rename(plan.changes); if not token then return false, err end
  local tokens, snapshots, moved = { token }, {}, false
  local params = { files = { { oldUri = vim.uri_from_fname(from), newUri = vim.uri_from_fname(to) } } }
  local clients = {}
  local ok, failure = xpcall(function()
    clients = relevant_clients(from, to)
    prepare_lsp(clients, params)
    -- A server may have loaded additional source buffers while applying edits.
    local seen = {}; for _, change in ipairs(plan.changes) do seen[change.buf] = true end
    plan.changes = changes_for(from, to, plan.directory)
    local additional = {}; for _, change in ipairs(plan.changes) do if not seen[change.buf] then additional[#additional + 1] = change end end
    local extra, extra_error = autosave.begin_rename(additional); assert(extra, extra_error); tokens[#tokens + 1] = extra
    local free, conflict = target_buffers(plan.changes, to, plan.directory); assert(free, conflict)
    for _, pending in ipairs(tokens) do local safe, reason = autosave.check_rename(pending); assert(safe, reason) end
    for _, change in ipairs(plan.changes) do
      if api.nvim_buf_is_loaded(change.buf) then snapshots[change.buf] = snapshot_buffer(change.buf) end
    end
    ensure_parent(to)
    for _, snapshot in pairs(snapshots) do detach_clients(snapshot) end
    move_disk(from, to, plan.case_only); moved = true
    for _, change in ipairs(plan.changes) do
      api.nvim_buf_set_name(change.buf, change.to)
      if snapshots[change.buf] then restore_buffer(snapshots[change.buf], true) end
    end
  end, debug.traceback)
  if not ok then
    -- Roll back only if the original name is still free. Never replace a file
    -- another process created while a callback was running.
    local restored = not moved or (not exists(from) and uv.fs_rename(to, from))
    for _, change in ipairs(plan.changes) do
      if api.nvim_buf_is_valid(change.buf) then
        if restored and moved then pcall(api.nvim_buf_set_name, change.buf, change.from) end
        if snapshots[change.buf] then
          local recovered = pcall(restore_buffer, snapshots[change.buf], moved and not not restored)
          if not recovered then pcall(restore_buffer, snapshots[change.buf], false) end
        end
      end
    end
  end
  for _, snapshot in pairs(snapshots) do
    local attached, attach_error = pcall(attach_clients, snapshot)
    if not attached then ok, failure = false, attach_error end
  end
  local operation_ok = ok
  for _, pending in ipairs(tokens) do
    local finished, reason = autosave.end_rename(pending, operation_ok)
    if ok and not finished then ok, failure = false, reason end
  end
  for _, snapshot in pairs(snapshots) do if snapshot.undo then fn.delete(snapshot.undo) end end
  if not ok then return false, tostring(failure) end
  for _, client in ipairs(clients) do
    if client:supports_method('workspace/didRenameFiles') then pcall(client.notify, client, 'workspace/didRenameFiles', params) end
  end
  return true
end
local function copy_one(from, to)
  assert(not exists(to), 'The destination already exists; nothing was overwritten.')
  local stat = assert(uv.fs_lstat(from), 'The source does not exist.')
  if stat.type == 'directory' then
    assert(uv.fs_mkdir(to, 493))
    local scan = assert(uv.fs_scandir(from))
    while true do
      local name = uv.fs_scandir_next(scan); if not name then break end
      copy_one(from .. '/' .. name, to .. '/' .. name)
    end
  elseif stat.type == 'file' then
    assert(uv.fs_copyfile(from, to, { excl = true }))
  elseif stat.type == 'link' then
    assert(uv.fs_symlink(assert(uv.fs_readlink(from)), to, { dir = fn.isdirectory(from) == 1 }))
  else error('This file type cannot be copied.') end
end
function M.copy_path(from, to)
  local ok, err = pcall(function()
    from, to = normalize(from), normalize(to)
    local allowed, reason = target_allowed(to); assert(allowed, reason)
    assert(not protected(from) and not protected(real(from)), 'The .git directory is protected.')
    assert(not exists(to), 'The destination already exists; nothing was overwritten.')
    local stat = assert(uv.fs_lstat(from), 'The source does not exist.')
    local free, conflict = target_buffers({}, to, stat.type == 'directory'); assert(free, conflict)
    assert(not within(to, from), 'A directory cannot be copied inside itself.')
    ensure_parent(to)
    copy_one(from, to)
  end)
  return ok, ok and nil or tostring(err)
end
function M.delete_paths(paths)
  local normalized, buffers = {}, {}
  local ok, err = pcall(function()
    for _, path in ipairs(paths) do
      path = normalize(path)
      local allowed, why = source_allowed(path); assert(allowed, why)
      assert(exists(path), 'The source does not exist.')
      for _, change in ipairs(affected(path, fn.isdirectory(path) == 1)) do
        assert(not vim.bo[change.buf].modified, 'A file has unsaved changes; deletion was cancelled.')
        buffers[change.buf] = true
      end
      normalized[#normalized + 1] = path
    end
    for _, path in ipairs(normalized) do
      local deleted, reason = require('snacks.explorer.actions').trash(path); assert(deleted, reason)
    end
    for buf in pairs(buffers) do
      require('config.autosave').forget(buf)
      if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = false }) end
    end
  end)
  return ok, ok and nil or tostring(err)
end
local function notify(ok, err)
  if not ok then
    M.last_error = tostring(err)
    local first = M.last_error:match('[^\r\n]+') or 'The operation failed.'
    first = first:match(':%d+: (.*)') or first
    local message = 'Explorer: ' .. first:gsub('%c', '?')
    while fn.strdisplaywidth(message) > math.max(1, vim.o.columns - 2) do message = fn.strcharpart(message, 0, fn.strchars(message) - 1) end
    vim.notify(message, vim.log.levels.ERROR)
  end
  return ok
end
local function refresh(picker, paths, target)
  if picker.closed then return end
  local tree = require('snacks.explorer.tree')
  for _, path in ipairs(paths) do tree:refresh(path) end
  if target then tree:open(vim.fs.dirname(target)) end
  require('snacks.explorer.actions').update(picker, { target = target, refresh = true })
end
local function selected(picker, fallback)
  local paths, seen = {}, {}
  for _, item in ipairs(picker:selected({ fallback = fallback })) do
    local path = normalize(item.file)
    local duplicate = false
    for _, parent in ipairs(paths) do if within(path, parent) then duplicate = true end end
    if not seen[key(path)] and not duplicate then paths[#paths + 1] = path; seen[key(path)] = true end
  end
  -- A parent selected after its child subsumes that child too.
  local result = {}
  for _, path in ipairs(paths) do
    local child = false
    for _, parent in ipairs(paths) do if parent ~= path and within(path, parent) then child = true end end
    if not child then result[#result + 1] = path end
  end
  return result
end
local function input_path(base, value)
  if value:match('^[/\\]') or value:match('^%a:[/\\]') then return normalize(value) end
  return normalize(base .. '/' .. value)
end
function M.actions.explorer_rename(picker, item)
  item = item or picker:current(); if not item then return end
  local from = normalize(item.file)
  local allowed, why = source_allowed(from); if not notify(allowed, why) then return end
  vim.ui.input({ prompt = 'Rename to: ', default = vim.fs.basename(from), completion = 'file' }, function(value)
    if not value or value:match('^%s*$') then return end
    local to = input_path(vim.fs.dirname(from), value)
    local ok, err = M.rename_path(from, to)
    if notify(ok, err) then refresh(picker, { vim.fs.dirname(from), vim.fs.dirname(to) }, to) end
  end)
end
function M.actions.explorer_move(picker, item)
  local paths = selected(picker, false)
  if #paths == 0 then return M.actions.explorer_rename(picker, item or picker:current()) end
  local target = normalize(picker:dir())
  for _, from in ipairs(paths) do
    local plan, err = validate_rename(from, target .. '/' .. vim.fs.basename(from)); if not notify(plan ~= nil, err) then return end
  end
  Snacks.picker.util.confirm(('Move %d selected item(s)?'):format(#paths), function()
    for _, from in ipairs(paths) do
      local to = target .. '/' .. vim.fs.basename(from)
      local ok, err = M.rename_path(from, to); if not notify(ok, err) then return end
    end
    picker.list:set_selected()
    refresh(picker, paths, target)
  end)
end
function M.actions.explorer_del(picker)
  local paths = selected(picker, true); if #paths == 0 then return end
  -- Recheck after confirmation too, since typing may have changed a file.
  for _, path in ipairs(paths) do
    local allowed, err = source_allowed(path); if not notify(allowed, err) then return end
    for _, change in ipairs(affected(path, fn.isdirectory(path) == 1)) do
      if not notify(not vim.bo[change.buf].modified, 'A file has unsaved changes; deletion was cancelled.') then return end
    end
  end
  Snacks.picker.util.confirm(('Delete %d selected item(s)?'):format(#paths), function()
    local ok, err = M.delete_paths(paths)
    if notify(ok, err) then picker.list:set_selected(); refresh(picker, paths) end
  end)
end
local function copy_selection(picker, paths)
  local target = normalize(picker:dir())
  local destinations = {}
  for _, from in ipairs(paths) do
    local destination = key(target .. '/' .. vim.fs.basename(from))
    if destinations[destination] then return notify(false, 'Two selected sources have the same destination name.') end
    destinations[destination] = true
    if not notify(not exists(target .. '/' .. vim.fs.basename(from)), 'The destination already exists; nothing was overwritten.') then return end
  end
  for _, from in ipairs(paths) do
    local to = target .. '/' .. vim.fs.basename(from)
    local ok, err = M.copy_path(from, to); if not notify(ok, err) then return end
  end
  picker.list:set_selected()
  refresh(picker, { target }, target)
end
function M.actions.explorer_copy(picker, item)
  local paths = selected(picker, false)
  if #paths > 0 then return copy_selection(picker, paths) end
  item = item or picker:current(); if not item then return end
  vim.ui.input({ prompt = 'Copy to: ', completion = 'file' }, function(value)
    if not value or value:match('^%s*$') then return end
    local to = input_path(vim.fs.dirname(item.file), value)
    local ok, err = M.copy_path(item.file, to)
    if notify(ok, err) then refresh(picker, { vim.fs.dirname(to) }, to) end
  end)
end
function M.actions.explorer_paste(picker)
  local paths = {}
  for _, path in ipairs(vim.split(fn.getreg(vim.v.register or '+'), '\n', { plain = true })) do
    if path ~= '' and exists(path) then paths[#paths + 1] = normalize(path) end
  end
  if #paths == 0 then return notify(false, 'The register contains no files or directories.') end
  copy_selection(picker, paths)
end
function M.actions.explorer_add(picker)
  vim.ui.input({ prompt = 'New file or directory (end directories with /): ', completion = 'file' }, function(value)
    if not value or value:match('^%s*$') then return end
    local ok, err = pcall(function()
      local target = input_path(picker:dir(), value)
      local allowed, why = target_allowed(target); assert(allowed, why)
      assert(not exists(target), 'The destination already exists; nothing was overwritten.')
      local free, conflict = target_buffers({}, target, value:match('[/\\]$') ~= nil); assert(free, conflict)
      ensure_parent(target)
      if value:match('[/\\]$') then assert(uv.fs_mkdir(target, 493))
      else local fd = assert(uv.fs_open(target, 'wx', 420)); assert(uv.fs_close(fd)) end
      refresh(picker, { vim.fs.dirname(target) }, target)
    end)
    notify(ok, err)
  end)
end
return M
