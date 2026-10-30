-- Run after normal init: nvim --headless -c "lua dofile(vim.fn.stdpath('config') .. '/scripts/bootstrap.lua')"
local ok, err = xpcall(function()
  assert(vim.g.my_nvim_ready == true, 'Neovim init did not complete; resolve the startup error before bootstrapping')
  local version = vim.version()
  if version.major ~= 0 or version.minor ~= 12 or version.patch ~= 6 then
    error('Neovim 0.12.6 is required')
  end
  require('config.tools').install()
  require('config.treesitter').install()

  local complete, native_ok, native_error = false, false, nil
  require('config.search').ensure_native(function(success, reason)
    native_ok, native_error, complete = success, reason, true
  end)
  if not vim.wait(300000, function() return complete end, 50) then
    error('FFF v0.11.0 native-library installation timed out')
  end
  if not native_ok then
    error('FFF v0.11.0 native-library installation failed: ' .. tostring(native_error))
  end
  print('Bootstrap complete. Restart Neovim before opening FFF if a DLL replacement was pending.')
end, debug.traceback)

if not ok then
  vim.api.nvim_err_writeln(tostring(err))
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
