-- Optional DeepSeek FIM transport and request guards around pinned Minuet virtualtext.
-- Credentials and code never enter status messages; Minuet's raw-response notices
-- are disabled. Its short-lived request JSON files are removed by its decoder.
local M = {}
local api, uv = vim.api, vim.uv
local machine, options = {}, {}
local state = { enabled = false, available = false, generation = 0, reason = 'not configured' }
local virtual, common, original_complete, original_start_job
local debounce_timer, deadline_timer
local last_notice = -math.huge
local DEFAULT_ENDPOINT = 'https://api.deepseek.com/beta/completions'
local DEFAULT_MODEL = 'deepseek-flash'

local function stop_timer(timer)
  if timer and not timer:is_closing() then timer:stop(); timer:close() end
end
local function key_value(value)
  if type(value) ~= 'string' then return nil end
  value = vim.trim(value)
  if value == '' or value:find('[\r\n]') then return nil end
  return value
end
local function eligible(allow_normal)
  if not state.enabled or (not allow_normal and vim.fn.mode() ~= 'i') then return false end
  local buf = api.nvim_get_current_buf()
  local name = api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= '' or not vim.bo[buf].modifiable or vim.bo[buf].readonly
    or name == '' or name:match('^%a[%w+.-]*://') or vim.fn.isdirectory(name) == 1 then return false end
  local basename = vim.fs.basename(name):lower()
  if basename == 'local.lua' or basename:match('^%.env') or basename == '.netrc'
    or basename == '.npmrc' or basename == '.pypirc' or basename:match('%.pem$')
    or basename:match('%.key$') then return false end
  return true
end
local function snapshot()
  return { buf = api.nvim_get_current_buf(), win = api.nvim_get_current_win(),
    tick = api.nvim_buf_get_changedtick(0), cursor = api.nvim_win_get_cursor(0), generation = state.generation }
end
local function current(request)
  return request and request.generation == state.generation and eligible()
    and api.nvim_get_current_buf() == request.buf and api.nvim_get_current_win() == request.win
    and api.nvim_buf_get_changedtick(request.buf) == request.tick
    and vim.deep_equal(api.nvim_win_get_cursor(request.win), request.cursor)
end
local function invalidate()
  state.generation = state.generation + 1
  stop_timer(debounce_timer); debounce_timer = nil
  stop_timer(deadline_timer); deadline_timer = nil
  state.pending, state.suggestion = nil, nil
  if common then common.terminate_all_jobs() end
  if virtual then pcall(virtual.action.dismiss) end
end
local function failure(message)
  state.last_error = message
  -- Only fixed messages supplied by this module are ever displayed.
  if uv.now() - last_notice >= 30000 then
    last_notice = uv.now()
    vim.notify('DeepSeek: ' .. message .. ' Ordinary completion remains available.', vim.log.levels.WARN)
  end
end
function M.dismiss() invalidate() end
function M.status()
  local visible = virtual and state.suggestion and current(state.suggestion.request)
    and virtual.action.is_visible() or false
  return { enabled = state.enabled, available = state.available, reason = state.reason,
    pending = state.pending ~= nil, visible = not not visible, generation = state.generation,
    last_error = state.last_error, model = state.model }
end

local function schedule()
  invalidate()
  if not eligible() then return end
  local request = snapshot()
  debounce_timer = vim.defer_fn(function()
    debounce_timer = nil
    if current(request) then M.trigger() end
  end, 800)
end
local function install_minuet()
  local minuet = require('minuet')
  minuet.setup({
    provider = 'openai_fim_compatible', notify = false,
    debounce = 800, throttle = 0, request_timeout = 5, n_completions = 1,
    context_window = 8000, context_ratio = 0.75,
    curl_cmd = state.curl, curl_extra_args = { '--silent', '--show-error', '--fail' },
    virtualtext = { auto_trigger_ft = {}, show_on_completion_menu = true, keymap = {} },
    duet = { recent_edits = { enabled = false }, auto_trigger = { auto_trigger_ft = {} } },
    lsp = { enabled_ft = {} },
    provider_options = { openai_fim_compatible = {
      name = 'DeepSeek', model = state.model, end_point = state.endpoint,
      api_key = function() return state.key end, stream = false,
      optional = { max_tokens = 256 },
      -- No default prompt annotations: these bounds apply to the complete wire
      -- prefix/suffix, counted as Unicode characters rather than UTF-8 bytes.
      template = {
        prompt = function(before) return vim.fn.strcharpart(before, math.max(0, vim.fn.strchars(before) - 6000)) end,
        suffix = function(_, after) return vim.fn.strcharpart(after, 0, 2000) end,
      },
    } },
  })
  virtual = require('minuet.virtualtext')
  common = require('minuet.backends.common')
  local provider = require('minuet.backends.openai_fim_compatible')
  original_complete = original_complete or provider.complete
  original_start_job = original_start_job or common.start_job

  -- Observe the subprocess result without forwarding curl stderr or API bodies.
  -- The original handler always runs so Minuet can unlink its temporary file,
  -- including when a canceled request finishes after its owner was invalidated.
  common.start_job = function(command, args, handlers)
    local request = state.pending
    if not request or not current(request) then
      if handlers.on_spawn_error then handlers.on_spawn_error() end
      return nil
    end
    local on_exit, on_spawn_error = handlers.on_exit, handlers.on_spawn_error
    handlers.on_exit = function(job, out)
      if out.code ~= 0 then
        request.error = out.code == 28 and 'Request timed out.' or 'Network or API request failed.'
      else
        local ok, result = pcall(vim.json.decode, out.stdout or '')
        if not ok or type(result) ~= 'table' or type(result.choices) ~= 'table'
          or type(result.choices[1]) ~= 'table' or type(result.choices[1].text) ~= 'string' then
          request.error = 'Invalid API response.'
        end
      end
      on_exit(job, out)
    end
    handlers.on_spawn_error = function()
      request.error = 'Could not start curl.'
      if on_spawn_error then on_spawn_error() end
    end
    return original_start_job(command, args, handlers)
  end
  provider.complete = function(context, callback)
    if not eligible() then callback({}); return end
    invalidate()
    local request = snapshot()
    state.pending, state.last_error = request, nil
    deadline_timer = vim.defer_fn(function()
      deadline_timer = nil
      if state.pending ~= request then return end
      invalidate()
      failure('Request timed out.')
    end, 5000)
    local ok = pcall(original_complete, context, function(items)
      if not current(request) or state.pending ~= request then return end
      stop_timer(deadline_timer); deadline_timer = nil
      state.pending = nil
      if request.error then
        failure(request.error)
        callback({})
        return
      end
      local text = type(items) == 'table' and items[1] or nil
      if type(text) == 'string' and text ~= '' then
        state.suggestion = { request = request, text = text }
      end
      local rendered = pcall(callback, text and { text } or {})
      if not rendered then
        invalidate()
        failure('Could not display the completion.')
      end
    end)
    if not ok then
      invalidate()
      failure('Could not prepare the completion request.')
    end
  end
end
local function configure()
  state.key = key_value(vim.env.DEEPSEEK_API_KEY) or key_value(options.api_key)
  state.endpoint = options.endpoint or DEFAULT_ENDPOINT
  state.model = options.model or DEFAULT_MODEL
  local curl_name = vim.fn.has('win32') == 1 and 'curl.exe' or 'curl'
  state.curl = vim.fn.executable(curl_name) == 1 and vim.fn.exepath(curl_name) or ''
  state.available = false
  if not state.key then state.reason = 'API key is not configured'
  elseif state.curl == '' then state.reason = 'curl is not available'
  elseif type(state.endpoint) ~= 'string' or not state.endpoint:match('^https?://%S+$')
    or type(state.model) ~= 'string' or state.model == '' then state.reason = 'Invalid endpoint or model'
  else state.available = true; state.reason = state.desired and 'ready' or 'disabled' end
  state.enabled = false
  if not state.desired or not state.available then return end
  local ok = pcall(install_minuet)
  if ok then state.enabled = true
  else state.available = false; state.reason = 'Minuet could not be initialized' end
end
function M.trigger()
  if not eligible() then return false end
  invalidate()
  -- The pinned Minuet release exposes manual triggering through action.next().
  -- Clearing its previous suggestion first ensures this starts a fresh request.
  local ok = pcall(virtual.action.next)
  if not ok then invalidate(); failure('Could not start completion.'); return false end
  return true
end
function M.accept()
  local suggestion = state.suggestion
  if not suggestion or not current(suggestion.request) or not virtual.action.is_visible() then return false end
  -- Blink invokes custom key handlers with textlock. Defer insertion and validate
  -- again: a queued Esc, buffer switch or another keystroke must never insert in
  -- the wrong file. Minuet's own accept callback uses buffer 0 without this gate.
  local cmp = package.loaded['blink.cmp']
  if cmp then cmp.hide() end
  vim.schedule(function()
    if state.suggestion ~= suggestion or not current(suggestion.request) then return end
    local request, text = suggestion.request, suggestion.text
    invalidate()
    local lines = vim.split(text, '\n', { plain = true })
    local row, col = request.cursor[1] - 1, request.cursor[2]
    api.nvim_buf_set_text(request.buf, row, col, row, col, lines)
    api.nvim_win_set_cursor(request.win, { row + #lines, #lines == 1 and col + #lines[1] or #lines[#lines] })
  end)
  return true
end
function M.toggle()
  invalidate()
  state.desired = not state.enabled
  configure()
  vim.notify('DeepSeek: ' .. (state.enabled and 'enabled' or state.reason), vim.log.levels.INFO)
  if state.enabled then schedule() end
  return state.enabled
end
function M.setup(value)
  invalidate()
  machine = value or {}
  options = type(machine.deepseek) == 'table' and machine.deepseek or {}
  state.desired = machine.deepseek ~= false and options.enabled ~= false
  state.last_error = nil
  configure()
  local group = api.nvim_create_augroup('my-nvim-ai-completion', { clear = true })
  api.nvim_create_autocmd({ 'InsertEnter', 'TextChangedI', 'TextChangedP', 'CursorMovedI' }, {
    group = group, callback = schedule,
  })
  api.nvim_create_autocmd({ 'InsertLeave', 'BufLeave', 'WinLeave', 'BufUnload', 'VimLeavePre' }, {
    group = group, callback = invalidate,
  })
  api.nvim_create_user_command('AICompletionToggle', M.toggle,
    { desc = 'Toggle optional DeepSeek inline completion', force = true })
  api.nvim_create_user_command('AICompletionTrigger', function()
    if not eligible(true) then
      vim.notify('DeepSeek: ' .. (state.enabled and 'Open an editable code file first.' or state.reason), vim.log.levels.INFO)
      return
    end
    if vim.fn.mode() == 'i' then M.trigger(); return end
    local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
    vim.cmd.startinsert()
    vim.schedule(function()
      if api.nvim_get_current_buf() == buf and api.nvim_get_current_win() == win then M.trigger() end
    end)
  end, { desc = 'Enter Insert mode and request DeepSeek inline completion', force = true })
  api.nvim_create_user_command('AICompletionStatus', function()
    local status = M.status()
    vim.notify(('DeepSeek: %s; request %s; suggestion %s%s'):format(
      status.enabled and 'enabled' or status.reason, status.pending and 'running' or 'idle',
      status.visible and 'visible' or 'hidden', status.last_error and '; ' .. status.last_error or ''), vim.log.levels.INFO)
  end, { desc = 'Show DeepSeek availability without credentials or code', force = true })
end
return M
