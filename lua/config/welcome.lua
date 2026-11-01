-- A persistent launcher window. Opening a project/file launches another instance.
local M = {}
local api = vim.api
local dashboard

local function project() return require('config.project') end

local function home_context()
  local launch = vim.g.my_nvim_project_launch
  return not (launch and launch ~= 0) and project().root() == nil and vim.fn.argc(-1) == 0
end

local function visible()
  return dashboard and api.nvim_buf_is_valid(dashboard.buf) and api.nvim_win_is_valid(dashboard.win)
    and api.nvim_win_get_buf(dashboard.win) == dashboard.buf
end

local function action(callback)
  return function()
    local ok, err = pcall(callback)
    if not ok then vim.notify('首页: ' .. tostring(err), vim.log.levels.ERROR) end
  end
end

local function display(value, width)
  value = tostring(value or ''):gsub('[\r\n\t]', ' ')
  if vim.fn.strdisplaywidth(value) <= width then return value end
  local count = vim.fn.strchars(value)
  local side = math.max(1, math.floor((width - 3) / 2))
  local left, right = vim.fn.strcharpart(value, 0, side), vim.fn.strcharpart(value, count - side)
  while vim.fn.strdisplaywidth(left .. '...' .. right) > width do
    if vim.fn.strdisplaywidth(left) > vim.fn.strdisplaywidth(right) then
      left = vim.fn.strcharpart(left, 0, math.max(0, vim.fn.strchars(left) - 1))
    else
      right = vim.fn.strcharpart(right, 1)
    end
  end
  return left .. '...' .. right
end

local function recent_files()
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  require('telescope.builtin').oldfiles({
    prompt_title = '最近文件（在新窗口打开）',
    attach_mappings = function(prompt_bufnr, map)
      local launch = action(function()
        local entry = action_state.get_selected_entry()
        local path = entry and (entry.path or entry.filename or entry.value)
        actions.close(prompt_bufnr)
        if type(path) == 'string' and path ~= '' then project().open_file(path) end
      end)
      -- Every opening variant keeps the launcher intact instead of splitting it.
      for _, name in ipairs({ 'select_default', 'select_horizontal', 'select_vertical', 'select_tab' }) do
        actions[name]:replace(launch)
      end
      for _, mode in ipairs({ 'i', 'n' }) do
        for _, key in ipairs({ '<CR>', '<C-x>', '<C-v>', '<C-t>' }) do map(mode, key, launch) end
      end
      return true
    end,
  })
end

local function mouse_action(self)
  if vim.b[self.buf].my_nvim_welcome_mouse then return end
  vim.b[self.buf].my_nvim_welcome_mouse = true
  vim.keymap.set('n', '<LeftMouse>', function()
    local mouse = vim.fn.getmousepos()
    if mouse.winid ~= self.win then
      api.nvim_feedkeys(api.nvim_replace_termcodes('<LeftMouse>', true, false, true), 'n', false)
      return
    end
    for _, item in ipairs(self.items or {}) do
      if item.action and item._ and mouse.line >= item._.row
        and mouse.line < item._.row + (item.welcome_lines or 1) then
        self:action(item.action)
        return
      end
    end
  end, { buffer = self.buf, silent = true, desc = '打开首页项目或操作' })
end

local function sections(self)
  dashboard = self
  self.opts.width = math.max(24, math.min(82, api.nvim_win_get_width(self.win) - 4))
  mouse_action(self)
  -- Snacks adds current keys but does not remove keys from a shorter MRU list.
  for index = 1, 8 do pcall(vim.keymap.del, 'n', tostring(index), { buffer = self.buf }) end
  local items = {
    { text = { { 'my-nvim', hl = 'header' } }, align = 'center', padding = 1 },
    { text = '项目与文件', align = 'center', padding = 1 },
  }
  local buttons = {
    { 'o', '打开文件夹', function() project().open() end },
    { 'f', '打开文件', function() project().open_file() end },
    { 'p', '全部项目', function() project().recent() end },
    { 'r', '最近文件', recent_files },
    { 'q', '退出此窗口', function() vim.cmd('confirm qall') end },
  }
  for _, button in ipairs(buttons) do
    items[#items + 1] = {
      key = button[1], text = '[' .. button[1] .. '] ' .. button[2],
      action = action(button[3]), welcome_lines = 1,
    }
  end
  items[#items + 1] = { text = '最近项目', padding = { 0, 1 } }
  local history = project().history()
  for index, entry in ipairs(history) do
    if index > 8 then break end
    local root = entry.root
    local name = entry.name or vim.fs.basename(root)
    if entry.exists == false then name = name .. ' [路径不存在]' end
    items[#items + 1] = {
      key = tostring(index), welcome_root = root, welcome_lines = 2,
      text = {
        { '[' .. index .. '] ' .. display(name, self.opts.width - 4) .. '\n', hl = 'desc' },
        { '    ' .. display(vim.fn.fnamemodify(root, ':~'), self.opts.width - 4),
          hl = entry.exists == false and 'DiagnosticWarn' or 'dir' },
      },
      action = action(function() project().open(root) end),
    }
  end
  if #history == 0 then items[#items + 1] = { text = '暂无最近项目，按 o 打开文件夹。' } end
  items[#items + 1] = {
    text = '上下方向键 / j、k 选择，Enter 打开；也可按数字或点击项目。', padding = { 0, 1 },
  }
  return items
end

function M.refresh()
  if not visible() then return false end
  local cursor = api.nvim_win_get_cursor(dashboard.win)
  local current = dashboard:find(cursor)
  local root = current and current.welcome_root
  dashboard:update()
  if root then
    for _, item in ipairs(dashboard.items) do
      if item.welcome_root == root and item._ then
        api.nvim_win_set_cursor(dashboard.win, { item._.row, 0 })
        break
      end
    end
  end
  return true
end

function M.show()
  if #api.nvim_list_uis() == 0 or not home_context() then return nil end
  if visible() then api.nvim_set_current_win(dashboard.win); M.refresh(); return dashboard end
  local buffer = api.nvim_get_current_buf()
  if vim.bo[buffer].modified or vim.bo[buffer].buftype ~= '' or api.nvim_buf_get_name(buffer) ~= ''
    or api.nvim_buf_line_count(buffer) ~= 1 or api.nvim_buf_get_lines(buffer, 0, 1, false)[1] ~= '' then
    return nil
  end
  return require('snacks.dashboard').open({ buf = buffer, win = api.nvim_get_current_win() })
end

function M.setup(_machine)
  local snacks = require('snacks')
  snacks.setup({
    dashboard = { enabled = home_context(), width = 82, sections = sections, preset = { keys = {}, header = '' } },
    picker = { enabled = false, ui_select = false, sources = { explorer = require('config.explorer').options() } }, terminal = { enabled = false },
    bigfile = { enabled = false }, quickfile = { enabled = false }, explorer = { enabled = true, replace_netrw = false },
    image = { enabled = false }, indent = { enabled = false }, input = { enabled = false },
    notifier = { enabled = false }, scope = { enabled = false }, scroll = { enabled = false },
    statuscolumn = { enabled = false }, words = { enabled = false },
  })
  local group = api.nvim_create_augroup('my-nvim-welcome', { clear = true })
  api.nvim_create_autocmd('FocusGained', {
    group = group, callback = function() vim.schedule(M.refresh) end,
  })
  api.nvim_create_autocmd('User', {
    group = group, pattern = 'ProjectHistoryChanged', callback = function() vim.schedule(M.refresh) end,
  })
end

return M
