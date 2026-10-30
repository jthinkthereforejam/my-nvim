-- nvim-treesitter main uses Neovim's native highlighter, not the old configs.setup API.
local M = {}
M.parsers = { 'c_sharp', 'c', 'cpp', 'rust', 'lua', 'vim', 'vimdoc', 'query', 'json', 'toml', 'bash', 'markdown', 'markdown_inline' }
local supported = {}
for _, language in ipairs(M.parsers) do supported[language] = true end

local function start(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) or vim.bo[bufnr].buftype ~= '' then return end
  local language = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype)
  if not language or not supported[language] then return end
  -- Missing parsers should not prevent editing, including before the first bootstrap.
  if pcall(vim.treesitter.language.add, language) then
    pcall(vim.treesitter.start, bufnr, language)
  end
end

function M.setup(_machine)
  require('nvim-treesitter').setup({ install_dir = vim.fs.joinpath(vim.fn.stdpath('data'), 'site') })
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('my-nvim-treesitter', { clear = true }),
    callback = function(args) start(args.buf) end,
  })
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do start(bufnr) end
  -- Jai uses jacket.nvim's syntax/jai.vim plus the server's semantic tokens.
end

-- Only bootstrap calls this: normal editor startup never downloads or compiles parsers.
function M.install()
  local treesitter = require('nvim-treesitter')
  treesitter.install(M.parsers):wait(300000)
  -- Reconcile existing parsers as well when the plugin lock changes or is restored.
  treesitter.update(M.parsers):wait(300000)
  local missing = {}
  for _, language in ipairs(M.parsers) do
    if not pcall(vim.treesitter.language.add, language) then table.insert(missing, language) end
  end
  assert(#missing == 0, 'Tree-sitter parsers failed to install: ' .. table.concat(missing, ', '))
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do start(bufnr) end
end

return M
