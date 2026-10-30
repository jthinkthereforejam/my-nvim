-- Native LSP configuration. Tools and machine paths are kept outside plugin specs.
local M = {}
local tools = require('config.tools')

local function executable_name(name)
  return vim.fn.has('win32') == 1 and (name .. '.exe') or name
end

local function jai_options(machine)
  local directory = machine.jacket or vim.fs.joinpath(tools.data_dir(), 'jacket', tools.jacket_version)
  return {
    server = { path = vim.fs.joinpath(directory, executable_name('jailsp')) },
    compiler = { path = vim.fs.joinpath(directory, executable_name('jaic')) },
    formatter = { path = vim.fs.joinpath(directory, executable_name('jaifmt')) },
    stdlib = { path = vim.fs.joinpath(directory, 'stdlib') },
    toolchain = { version = tools.jacket_version, auto_download = 'never' },
    format_on_save = false,
    -- Enable only after completion capabilities and local paths have been applied.
    lsp = { enable = false },
  }
end

-- Run before vim.pack.add(): both language plugins have startup scripts.
function M.prepare(machine)
  machine = machine or {}
  vim.g.jai = jai_options(machine)
  vim.lsp.config('roslyn', { cmd = tools.roslyn_command(machine) })
end

local function attach(args)
  local bufnr = args.buf
  local function map(keys, callback, description, modes)
    vim.keymap.set(modes or 'n', keys, callback, { buffer = bufnr, desc = description, silent = true })
  end

  map('gd', vim.lsp.buf.definition, 'Definition')
  map('grd', vim.lsp.buf.definition, 'Definition')
  map('grr', vim.lsp.buf.references, 'References')
  map('gri', vim.lsp.buf.implementation, 'Implementation')
  map('grt', vim.lsp.buf.type_definition, 'Type definition')
  map('grn', vim.lsp.buf.rename, 'Rename')
  map('gra', vim.lsp.buf.code_action, 'Code action', { 'n', 'x' })
  map('K', vim.lsp.buf.hover, 'Hover documentation')
  map('[d', function() vim.diagnostic.jump({ count = -1, float = true }) end, 'Previous diagnostic')
  map(']d', function() vim.diagnostic.jump({ count = 1, float = true }) end, 'Next diagnostic')
  map('<leader>th', function()
    if #vim.lsp.get_clients({ bufnr = bufnr, method = 'textDocument/inlayHint' }) == 0 then
      vim.notify('This buffer has no LSP server with inlay hints.', vim.log.levels.INFO)
      return
    end
    local enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr })
    vim.lsp.inlay_hint.enable(not enabled, { bufnr = bufnr })
  end, 'Toggle inlay hints')

  -- Semantic tokens are enabled by Neovim when the server supports them.
  -- No save/type formatting autocmd is registered: formatting stays explicit.
end

function M.setup(machine)
  machine = machine or {}
  local capabilities = require('blink.cmp').get_lsp_capabilities()
  vim.lsp.config('*', { capabilities = capabilities })
  vim.lsp.on_type_formatting.enable(false)

  vim.api.nvim_create_autocmd('LspAttach', {
    group = vim.api.nvim_create_augroup('my-nvim-lsp', { clear = true }),
    callback = attach,
  })

  local roslyn_command = tools.roslyn_command(machine)
  require('roslyn').setup({ broad_search = false, lock_target = false })
  vim.lsp.config('roslyn', {
    cmd = roslyn_command,
    settings = {
      ['csharp|completion'] = {
        dotnet_show_completion_items_from_unimported_namespaces = true,
      },
      ['csharp|inlay_hints'] = {
        csharp_enable_inlay_hints_for_implicit_object_creation = true,
        csharp_enable_inlay_hints_for_implicit_variable_types = true,
        csharp_enable_inlay_hints_for_lambda_parameter_types = true,
      },
    },
  })
  -- The Roslyn plugin enables itself; pause it if bootstrap has not installed its tool yet.
  vim.lsp.enable('roslyn', vim.fn.executable(roslyn_command[1]) == 1)

  local clangd = tools.executable(machine, 'clangd', 'clangd')
  vim.lsp.config('clangd', {
    cmd = { clangd, '--background-index' },
    -- Build metadata works with manual scripts, Make, CMake, or any other build system.
    root_markers = { { '.clangd', 'compile_commands.json', 'compile_flags.txt' }, '.git' },
  })
  vim.lsp.enable('clangd', vim.fn.executable(clangd) == 1)

  local rust_analyzer = tools.executable(machine, 'rust_analyzer', 'rust-analyzer')
  vim.lsp.config('rust_analyzer', {
    cmd = { rust_analyzer },
    settings = {
      ['rust-analyzer'] = {
        cargo = { buildScripts = { enable = true } },
        procMacro = { enable = true },
        check = { command = 'check' },
      },
    },
  })
  vim.lsp.enable('rust_analyzer', vim.fn.executable(rust_analyzer) == 1)

  local jai = jai_options(machine)
  require('jai').setup(jai)
  vim.lsp.config('jailsp', { capabilities = capabilities })
  vim.lsp.enable('jailsp', vim.fn.executable(jai.server.path) == 1)
end

return M
