-- Editing-time Git feedback. Repository operations remain in Fork/CLI.
local M = {}
local api = vim.api

local function colors()
  local links = { Add = 'GreenSign', Change = 'YellowSign', Delete = 'RedSign',
    Topdelete = 'RedSign', Changedelete = 'RedSign', Untracked = 'GreenSign' }
  for kind, target in pairs(links) do api.nvim_set_hl(0, 'GitSigns' .. kind, { link = target }) end
end

local function root()
  if vim.fn.executable('git') ~= 1 then return nil, 'Git is not available on PATH.' end
  local cwd = require('config.search').project_root()
  if not require('config.project').root() and vim.bo.buftype ~= '' then
    -- A direct `nvim /repo/file` launch can keep cwd outside the repository.
    -- Special views should still use their originating code file's repository.
    local state = require('config.git_diff').status()
    local buf = state.visible and state.buf or nil
    if not buf then
      local win = require('config.explorer').status().main_win
      if win and api.nvim_win_is_valid(win) then buf = api.nvim_win_get_buf(win) end
    end
    if buf and api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == '' then
      local name = api.nvim_buf_get_name(buf)
      if name ~= '' then cwd = vim.fs.dirname(name) end
    end
  end
  local result = vim.system({ 'git', '-C', cwd, 'rev-parse', '--show-toplevel' }, { text = true }):wait(3000)
  if result.code ~= 0 then return nil, 'This project is not a Git working tree.' end
  return vim.trim(result.stdout)
end

local function editing_window()
  local diff = require('config.git_diff')
  local state = diff.status()
  if state.visible then diff.close() end
  -- Reuse the tree's normal editor selection, including hiding a managed or
  -- manually created terminal without ending its shell or changing its cwd.
  return require('config.explorer').edit_window()
end

function M.changes()
  local cwd, err = root()
  if not cwd then vim.notify('Git: ' .. err, vim.log.levels.INFO); return false end
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local ok, why = pcall(require('telescope.builtin').git_status, {
    cwd = cwd, use_git_root = true, prompt_title = 'Git Changes (disk vs HEAD)',
    disable_devicons = true,
    git_icons = { added = 'A', changed = 'M', copied = 'C', deleted = 'D',
      renamed = 'R', unmerged = 'U', untracked = '?' },
    get_selection_window = editing_window,
    attach_mappings = function(prompt, map)
      -- The builtin maps Tab to git_staging_toggle. Override it after its own
      -- attach callback; keep the picker a browser in both input modes.
      map({ 'i', 'n' }, '<Tab>', actions.move_selection_next)
      map({ 'i', 'n' }, '<S-Tab>', actions.move_selection_previous)
      map({ 'i', 'n' }, '<CR>', function()
        local entry = action_state.get_selected_entry()
        if not entry then return end
        if vim.fn.filereadable(entry.path) ~= 1 then
          vim.notify('Git: This file no longer exists; its deletion is available in the preview.', vim.log.levels.INFO)
          return
        end
        actions.select_default(prompt)
      end)
      return true
    end,
  })
  if not ok then
    M.last_error = tostring(why)
    vim.notify('Git: Changes list unavailable here; use :GitDiffToggle.', vim.log.levels.WARN)
    return false
  end
  return true
end

function M.navigate(direction)
  if vim.wo.diff then
    vim.cmd.normal({ args = { direction == 'next' and ']c' or '[c' }, bang = true })
  elseif not require('config.git_newfiles').navigate(direction) then
    require('gitsigns').nav_hunk(direction)
  end
end
function M.preview()
  local state = require('config.git_diff').status()
  if state.visible and api.nvim_get_current_win() == state.left_win and api.nvim_win_is_valid(state.right_win) then
    api.nvim_set_current_win(state.right_win)
  end
  if require('config.git_newfiles').preview() then return end
  if not require('gitsigns').get_hunks() then
    vim.notify('Git: No Git changes are available for this buffer.', vim.log.levels.INFO)
    return
  end
  require('gitsigns').preview_hunk()
end

function M.toggle_signs()
  local enabled = require('gitsigns').toggle_signs()
  require('config.git_newfiles').redraw(enabled)
  return enabled
end

function M.setup()
  require('gitsigns').setup({
    base = 'HEAD', signs_staged_enable = false, attach_to_untracked = true,
    update_debounce = 100, signcolumn = true, sign_priority = 6,
    numhl = false, linehl = false, word_diff = false, current_line_blame = false,
    signs = {
      add = { text = '+' }, change = { text = '~' }, delete = { text = '_' },
      topdelete = { text = '^' }, changedelete = { text = '~' }, untracked = { text = '+' },
    },
    -- The file tree owns buffer-preserving renames; let Git refresh attach state
    -- without a second component renaming the same loaded buffer.
    watch_gitdir = { enable = true, follow_files = false },
    preview_config = { border = 'rounded' },
    on_attach = function(buf)
      for keys, direction in pairs({ [']c'] = 'next', ['[c'] = 'prev' }) do
        vim.keymap.set('n', keys, function()
          M.navigate(direction)
        end, { buffer = buf, desc = direction == 'next' and 'Next Git change' or 'Previous Git change', silent = true })
      end
    end,
  })
  colors()
  api.nvim_create_autocmd('ColorScheme', {
    group = api.nvim_create_augroup('my-nvim-git-colors', { clear = true }), callback = colors,
  })
  require('config.git_diff').setup()
  require('config.git_newfiles').setup()
  local function toggle_diff() return require('config.git_diff').toggle() end
  local function map(keys, callback, description)
    vim.keymap.set('n', keys, callback, { desc = description, silent = true })
  end
  map(']c', function() M.navigate('next') end, 'Next Git change')
  map('[c', function() M.navigate('prev') end, 'Previous Git change')
  map('<leader>gp', M.preview, 'Preview Git change')
  map('<leader>gd', toggle_diff, 'Toggle file diff against HEAD')
  map('<leader>gs', M.changes, 'Git changed files (disk)')
  map('<leader>gt', M.toggle_signs, 'Toggle Git signs')
  api.nvim_create_user_command('GitDiffToggle', toggle_diff, { desc = 'Toggle current file diff against HEAD', force = true })
  api.nvim_create_user_command('GitChanges', M.changes, { desc = 'Browse Git changes on disk', force = true })
end

return M
