-- Set NVIM_TEST_JAI_PROJECT to an existing latticeon checkout, then run:
-- nvim --headless -u /path/to/my-nvim/init.lua "+lua dofile('/path/to/my-nvim/tests/jai_project.lua')"
-- This test reads the project; it never writes source files or applies edits.
-- This suite exercises explicit saves and preservation of unsaved buffers.
require('config.autosave').setup({ autosave = { enabled = false } })
local root = assert(vim.env.NVIM_TEST_JAI_PROJECT, 'Set NVIM_TEST_JAI_PROJECT to the latticeon checkout')
local paths = {
  main = vim.fs.joinpath(root, 'src/main.jai'), game = vim.fs.joinpath(root, 'src/game.jai'),
  platform = vim.fs.joinpath(root, 'src/platform.jai'),
}
local originals = {}
for name, path in pairs(paths) do originals[name] = table.concat(vim.fn.readfile(path, 'b'), '\n') end

local function edit(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  local client
  assert(vim.wait(45000, function()
    for _, item in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = 'jailsp' })) do
      if item.initialized then client = item; return true end
    end
    return false
  end, 50), 'Jacket did not attach to ' .. path)
  return bufnr, client
end

local function find(lines, pattern, symbol)
  for index, line in ipairs(lines) do
    if line:match(pattern) then
      return { line = index - 1, character = assert(line:find(symbol, 1, true)) - 1 }
    end
  end
  error('Missing project symbol: ' .. symbol)
end

local function request(client, method, params, valid, description)
  local deadline = vim.uv.hrtime() + 45e9
  local last_error
  repeat
    local response, err = client:request_sync(method, params, 5000)
    if response and not response.err and valid(response.result) then return response.result end
    last_error = response and response.err or err
    vim.wait(250, function() return false end)
  until vim.uv.hrtime() > deadline
  error(description .. ': ' .. vim.inspect(last_error))
end

vim.schedule(function()
  local ok, err = xpcall(function()
    local main_buf, main_client = edit(paths.main)
    local game_buf, client = edit(paths.game)
    local game_lines = vim.api.nvim_buf_get_lines(game_buf, 0, -1, true)
    local document = { uri = vim.uri_from_bufnr(game_buf) }
    request(client, 'textDocument/hover', {
      textDocument = document, position = find(game_lines, '^GameState%s*::', 'GameState'),
    }, function(result)
      return result and result ~= vim.NIL and vim.inspect(result.contents):find('GameState', 1, true) ~= nil
    end, 'GameState hover failed')
    request(client, 'textDocument/definition', {
      textDocument = document, position = find(game_lines, 'memory:%s*%*GameMemory', 'GameMemory'),
    }, function(result)
      if not result or result == vim.NIL then return false end
      for _, location in ipairs((result.uri or result.targetUri) and { result } or result) do
        local uri = location.uri or location.targetUri
        if uri and vim.fs.normalize(vim.uri_to_fname(uri)):lower() == vim.fs.normalize(paths.platform):lower() then return true end
      end
      return false
    end, 'GameMemory cross-file definition failed')
    request(client, 'textDocument/semanticTokens/full', { textDocument = document }, function(result)
      return result and result ~= vim.NIL and result.data and #result.data > 0
    end, 'Game source semantic tokens failed')
    for _, target in ipairs({ { main_buf, main_client }, { game_buf, client } }) do
      local report = request(target[2], 'textDocument/diagnostic', {
        textDocument = { uri = vim.uri_from_bufnr(target[1]) },
      }, function(result) return result and result ~= vim.NIL and result.kind == 'full' end, 'Project diagnostics failed')
      for _, diagnostic in ipairs(report.items or {}) do
        assert(diagnostic.severity ~= 1, 'Jai project error: ' .. diagnostic.message)
      end
    end
    for name, path in pairs(paths) do
      assert(originals[name] == table.concat(vim.fn.readfile(path, 'b'), '\n'), 'Project source changed: ' .. path)
      local bufnr = vim.fn.bufnr(path)
      if bufnr >= 0 then assert(not vim.bo[bufnr].modified, 'Project buffer was modified: ' .. path) end
    end
    print('PASS real Jai project: main/game attached, GameState hover, GameMemory definition, semantic tokens, zero error diagnostics, sources unchanged')
  end, debug.traceback)
  if not ok then
    vim.api.nvim_err_writeln(err)
    vim.cmd('cquit 1')
  else
    vim.cmd('qa!')
  end
end)
