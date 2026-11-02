-- Explicit code formatting. gw keeps its motion/selection workflow and cursor.
-- Jai uses Jacket's formatter; other languages use their attached LSP server.
local M = {}
local api = vim.api
local operator_view

local function notice(message)
  vim.notify('Format: ' .. message, vim.log.levels.WARN)
  return false, message
end

local function unchanged(buf, tick, name)
  return api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf)
    and api.nvim_buf_get_changedtick(buf) == tick and api.nvim_buf_get_name(buf) == name
end

local function line_edits(before, after, first, last, label, ignore_outside)
  local hunks = vim.text.diff(table.concat(before, '\n') .. '\n', table.concat(after, '\n') .. '\n', {
    result_type = 'indices', algorithm = 'histogram', linematch = 60,
  })
  local edits = {}
  for _, hunk in ipairs(hunks) do
    local a, count_a, b, count_b = unpack(hunk)
    local start = count_a == 0 and a or a - 1
    local finish = start + count_a
    -- A zero-line hunk is an insertion after line a. Interior insertions
    -- belong to the range; an edge insertion needs that document edge selected.
    local inside, outside = true, false
    if first then
      if count_a == 0 then
        inside = a >= first and a < last or a == 0 and first == 1 or a == #before and last == #before
        outside = a < first - 1 or a > last
      else
        inside = start >= first - 1 and finish <= last
        outside = finish <= first - 1 or start >= last
      end
    end
    if inside then
      edits[#edits + 1] = { start, finish, count_b == 0 and {} or vim.list_slice(after, b, b + count_b - 1) }
    elseif not outside or not ignore_outside then
      return nil, label .. ' changes cross the selected lines; expand the selection or use :Format.'
    end
  end
  return edits
end

local function jai_edits(buf, lines, first, last)
  local formatter, find_error = require('jai.toolchain').find('jaifmt')
  if not formatter then return nil, find_error or 'Jacket jaifmt was not found; run :checkhealth jai.' end
  local name = api.nvim_buf_get_name(buf)
  if name ~= '' and require('jai.format').is_ignored(formatter.path, name) then
    return nil, 'This file is excluded by Jacket [format].ignore.'
  end
  local input = table.concat(lines, '\n') .. '\n'
  local ok, job = pcall(vim.system, { formatter.path, '--stdin' }, {
    stdin = input, text = true, cwd = name ~= '' and vim.fs.dirname(name) or vim.uv.cwd(),
  })
  if not ok then return nil, 'Could not start jaifmt: ' .. tostring(job) end
  local output = job:wait(10000)
  if output.code ~= 0 then
    local reason = vim.trim(output.stderr or ''):gsub('%s*\n%s*', ' ')
    return nil, output.code == 124 and 'jaifmt timed out.'
      or ('jaifmt: ' .. (reason ~= '' and reason or ('exit ' .. tostring(output.code))))
  end
  local formatted = vim.split((output.stdout or ''):gsub('\n$', ''), '\n', { plain = true })
  return line_edits(lines, formatted, first, last, 'Jacket', true)
end

local function lsp_edits(buf, lines, first, last)
  local method = first and 'textDocument/rangeFormatting' or 'textDocument/formatting'
  local clients = vim.lsp.get_clients({ bufnr = buf, method = method })
  table.sort(clients, function(a, b) return a.name == b.name and a.id < b.id or a.name < b.name end)
  local client = clients[1]
  if not client then
    return nil, first and 'No attached LSP supports selection formatting; use :Format for the whole file.'
      or 'No attached LSP supports formatting for this file.'
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    options = { tabSize = vim.bo[buf].shiftwidth > 0 and vim.bo[buf].shiftwidth or vim.bo[buf].tabstop,
      insertSpaces = vim.bo[buf].expandtab },
  }
  if first then
    params.range = { start = { line = first - 1, character = 0 }, ['end'] = {
      line = last - 1,
      character = vim.lsp.util.character_offset(buf, last - 1, #lines[last], client.offset_encoding),
    } }
  end
  local response, err = client:request_sync(method, params, 5000, buf)
  if not response or response.err then
    return nil, client.name .. ': ' .. tostring(response and response.err and response.err.message or err or 'request failed')
  end
  local edits = response.result
  if edits == nil or edits == vim.NIL then edits = {} end
  if first then
    -- LSP edits often include the previous line's newline just to indent the
    -- selected line. Check their actual text changes, rather than raw ranges.
    -- This also catches edits that accidentally join an unselected next line.
    local scratch = api.nvim_create_buf(false, true)
    local ok, formatted = xpcall(function()
      vim.bo[scratch].undolevels = -1
      api.nvim_buf_set_lines(scratch, 0, -1, true, lines)
      vim.lsp.util.apply_text_edits(edits, scratch, client.offset_encoding)
      return api.nvim_buf_get_lines(scratch, 0, -1, true)
    end, debug.traceback)
    api.nvim_buf_delete(scratch, { force = true })
    if not ok then return nil, client.name .. ' returned invalid formatting edits.' end
    return line_edits(lines, formatted, first, last, client.name, false)
  end
  return edits, nil, client.offset_encoding
end

-- first/last are inclusive, one-based lines, matching Vim's gw and Ex ranges.
function M.format(opts)
  opts = opts or {}
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  if vim.bo[buf].buftype ~= '' or not vim.bo[buf].modifiable or vim.bo[buf].readonly then
    return notice('Use a writable, ordinary text buffer.')
  end
  local view = vim.fn.winsaveview()
  local tick, name = api.nvim_buf_get_changedtick(buf), api.nvim_buf_get_name(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
  local first, last = opts.first, opts.last
  if first then
    first, last = math.min(first, last or first), math.max(first, last or first)
    first, last = math.max(1, first), math.min(#lines, last)
    if first > last then return notice('The selected lines are no longer valid.') end
  end
  local jai = vim.bo[buf].filetype == 'jai'
  local edits, err, encoding
  if jai then edits, err = jai_edits(buf, lines, first, last)
  else edits, err, encoding = lsp_edits(buf, lines, first, last) end
  if not edits then return notice(err) end
  if not unchanged(buf, tick, name) then return notice('The buffer changed while formatting; please try again.') end
  if jai or not encoding then
    for index = #edits, 1, -1 do
      if index < #edits then api.nvim_buf_call(buf, function() vim.cmd('undojoin') end) end
      local edit = edits[index]
      api.nvim_buf_set_lines(buf, edit[1], edit[2], true, edit[3])
    end
  else
    vim.lsp.util.apply_text_edits(edits, buf, encoding)
  end
  if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
    api.nvim_win_call(win, function() vim.fn.winrestview(view) end)
  end
  return true
end

function M.visual()
  local first, last = vim.fn.line('v'), vim.fn.line('.')
  -- Leave Visual mode before writing; preserve its marks for gv and :'<,'>Format.
  vim.cmd.normal({ args = { '\027' }, bang = true })
  return M.format({ first = first, last = last })
end

function M.operator()
  local view = operator_view
  operator_view = nil
  M.format({ first = vim.fn.line("'["), last = vim.fn.line("']") })
  if view and api.nvim_get_current_buf() == view.buf then vim.fn.winrestview(view.view) end
end

function M.setup()
  vim.keymap.set('x', 'gw', M.visual, { desc = 'Format selected lines', silent = true })
  vim.keymap.set('n', 'gw', function()
    operator_view = { buf = api.nvim_get_current_buf(), view = vim.fn.winsaveview() }
    vim.go.operatorfunc = "v:lua.require'config.formatting'.operator"
    return 'g@'
  end, { expr = true, desc = 'Format code (motion)', silent = true })
  vim.api.nvim_create_user_command('Format', function(args)
    M.format(args.range > 0 and { first = args.line1, last = args.line2 } or nil)
  end, { range = true, desc = 'Format file or selected lines (Jacket / LSP)' })
end

return M
