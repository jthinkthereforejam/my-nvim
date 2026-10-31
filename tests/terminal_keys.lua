-- nvim --headless -c "lua dofile(vim.fn.stdpath('config') .. '/tests/terminal_keys.lua')"
-- Exercise actual normal/insert/terminal key dispatch, without replacing callbacks.
assert(vim.g.my_nvim_ready, 'Load the my-nvim configuration before this test')
local api, fn = vim.api, vim.fn
local terminal = require('config.terminal')
local root = vim.fs.joinpath(fn.stdpath('cache'), 'my-nvim-terminal-key-tests', tostring(vim.uv.os_getpid()))
local done, editor, first_job = false, nil, nil
local function cleanup()
  local jobs = {}
  for _, session in ipairs(terminal.sessions(root)) do
    if session.job and session.job > 0 then jobs[#jobs + 1] = session.job; pcall(fn.jobstop, session.job) end
  end
  if #jobs > 0 then pcall(fn.jobwait, jobs, 5000) end
end
local function finish(ok, err)
  if done then return end
  done = true
  cleanup()
  if ok then
    print('PASS terminal keys: actual Ctrl-j in normal/insert/terminal modes, mode restoration, unchanged unsaved text, leader tt/tn/tx, command registration')
    vim.cmd('qa!')
  else
    api.nvim_err_writeln(err)
    vim.cmd('cquit 1')
  end
end
local function guarded(callback)
  if done then return end
  local ok, err = xpcall(callback, debug.traceback)
  if not ok then finish(false, err) end
end
local function input(keys)
  assert(api.nvim_input(api.nvim_replace_termcodes(keys, true, false, true)) > 0, 'Neovim rejected keyboard input: ' .. keys)
end
local function eventually(predicate, callback, description, deadline)
  deadline = deadline or (vim.uv.hrtime() + 10e9)
  vim.defer_fn(function()
    guarded(function()
      if predicate() then callback()
      elseif vim.uv.hrtime() >= deadline then
        error(description .. '; mode=' .. api.nvim_get_mode().mode .. '; status=' .. vim.inspect(terminal.status()))
      else eventually(predicate, callback, description, deadline) end
    end)
  end, 25)
end
local function visible() local state = terminal.status(); return state.win and api.nvim_win_is_valid(state.win) end
local function editing(mode)
  return not visible() and api.nvim_get_current_buf() == editor and api.nvim_get_mode().mode:sub(1, 1) == mode
end
local function terminal_mode() return visible() and api.nvim_get_mode().mode == 't' end
local function active()
  local state = terminal.status()
  for _, session in ipairs(terminal.sessions(root)) do if session.id == state.active then return session end end
  error('The selected terminal session is missing')
end
local function unchanged()
  assert(vim.bo[editor].modified and api.nvim_buf_get_lines(editor, 0, -1, true)[1] == 'unsaved keyboard fixture',
    'The toggle key inserted text or saved the editor buffer')
end

vim.schedule(function()
  guarded(function()
    fn.mkdir(root, 'p')
    local result = vim.system({ 'git', 'init', '--quiet', root }, { text = true }):wait(10000)
    assert(result.code == 0, 'Could not create a disposable Git project')
    fn.chdir(root)
    local file = vim.fs.joinpath(root, 'notes.txt')
    fn.writefile({ 'saved keyboard fixture' }, file)
    vim.cmd.edit(fn.fnameescape(file))
    editor = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(editor, 0, -1, false, { 'unsaved keyboard fixture' })
    for _, name in ipairs({ 'TerminalToggle', 'TerminalNew', 'TerminalSelect', 'TerminalClose' }) do
      assert(fn.exists(':' .. name) == 2, name .. ' was not registered')
    end
    input('<C-j>')
    eventually(terminal_mode, function()
      first_job = active().job
      unchanged()
      input('<C-j>')
      eventually(function() return editing('n') end, function()
        unchanged()
        input('i')
        eventually(function() return api.nvim_get_mode().mode:sub(1, 1) == 'i' end, function()
          input('<C-j>')
          eventually(terminal_mode, function()
            assert(active().job == first_job, 'Insert-mode toggle started a different shell')
            input('<C-j>')
            eventually(function() return editing('i') end, function()
              unchanged()
              input('<Esc>')
              eventually(function() return editing('n') end, function()
                input(' tt')
                eventually(terminal_mode, function()
                  assert(active().job == first_job, 'Leader tt did not reuse the terminal job')
                  input(string.char(28) .. '<C-n>')
                  eventually(function() return api.nvim_get_mode().mode:sub(1, 1) == 'n' end, function()
                    input(' tn')
                    eventually(function() return terminal_mode() and #terminal.sessions(root) == 2 end, function()
                      assert(active().job ~= first_job, 'Leader tn did not create another shell')
                      input(string.char(28) .. '<C-n>')
                      eventually(function() return api.nvim_get_mode().mode:sub(1, 1) == 'n' end, function()
                        input(' tx')
                        eventually(function() return #terminal.sessions(root) == 1 end, function()
                          unchanged()
                          assert(fn.readfile(file)[1] == 'saved keyboard fixture', 'Keyboard toggles wrote the editing file')
                          finish(true)
                        end, 'Leader tx did not close the selected session')
                      end, 'Could not enter terminal-normal mode before close')
                    end, 'Leader tn did not create and display a second terminal')
                  end, 'Could not enter terminal-normal mode before new')
                end, 'Leader tt did not show the terminal')
              end, 'Escape did not restore normal editor mode')
            end, 'Terminal Ctrl-j did not restore the prior insert mode')
          end, 'Insert Ctrl-j did not enter the terminal')
        end, 'Could not enter editor insert mode')
      end, 'Terminal Ctrl-j did not restore normal editor mode')
    end, 'Normal Ctrl-j did not open and enter the terminal')
  end)
end)
