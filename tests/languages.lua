-- Run with the complete configuration, not --clean:
-- nvim --headless -c "lua dofile(vim.fn.stdpath('config') .. '/tests/languages.lua')"
-- Optional: NVIM_TEST_LANGUAGES=cpp,rust,cs,jai selects a subset.
-- Fixtures and build metadata live under stdpath('cache')/my-nvim-tests only.
local api = vim.api
local base = vim.fs.joinpath(vim.fn.stdpath('cache'), 'my-nvim-tests', tostring(vim.uv.os_getpid()))
local selected = {}
for name in (vim.env.NVIM_TEST_LANGUAGES or 'cpp,rust,cs,jai'):gmatch('[^,]+') do selected[name] = true end

local function write(root, name, lines)
  local path = vim.fs.joinpath(root, name)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(type(lines) == 'table' and lines or vim.split(lines, '\n', { plain = true }), path)
  return path
end

local function position(lines, line, needle, after)
  local col = assert(lines[line + 1]:find(needle, 1, true), 'Missing fixture text: ' .. needle) - 1
  return { line = line, character = col + (after and #needle or 0) }
end

local function request_until(client, method, params, accepts, description)
  local result, last_error, received
  local deadline = vim.uv.hrtime() + 45e9
  repeat
    local response, err = client:request_sync(method, params, 5000)
    if response and not response.err and accepts(response.result) then
      result = response.result
      received = true
      break
    end
    last_error = response and response.err or err
    vim.wait(250, function() return false end)
  until vim.uv.hrtime() >= deadline
  assert(received, description .. ' failed: ' .. vim.inspect(last_error))
  return result
end

local function has_definition(result, expected)
  if not result or result == vim.NIL then return false end
  local locations = (result.uri or result.targetUri) and { result } or result
  for _, location in ipairs(locations) do
    local uri = location.uri or location.targetUri
    if uri and vim.fs.normalize(vim.uri_to_fname(uri)):lower() == vim.fs.normalize(expected):lower() then return true end
  end
  return false
end

local function check(spec)
  local path = write(spec.root, spec.file, spec.lines)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local bufnr = api.nvim_get_current_buf()
  local client
  assert(vim.wait(45000, function()
    for _, candidate in ipairs(vim.lsp.get_clients({ name = spec.server, bufnr = bufnr })) do
      if candidate.initialized then client = candidate; return true end
    end
    return false
  end, 50), spec.name .. ': language server did not attach')

  local document = { uri = vim.uri_from_bufnr(bufnr) }
  request_until(client, 'textDocument/definition', {
    textDocument = document,
    position = spec.definition,
  }, function(result) return has_definition(result, spec.definition_file) end, spec.name .. ' cross-file definition')

  request_until(client, 'textDocument/hover', {
    textDocument = document,
    position = spec.hover,
  }, function(result)
    return result and result ~= vim.NIL and vim.inspect(result.contents):find('Counter', 1, true) ~= nil
  end, spec.name .. ' hover')

  request_until(client, 'textDocument/completion', {
    textDocument = document,
    position = spec.completion,
    context = { triggerKind = 1 },
  }, function(result)
    if not result or result == vim.NIL then return false end
    for _, item in ipairs(result.items or result) do
      if item.label and item.label:find(spec.member, 1, true) then return true end
    end
    return false
  end, spec.name .. ' member completion')

  request_until(client, 'textDocument/semanticTokens/full', { textDocument = document }, function(result)
    return result and result ~= vim.NIL and result.data and #result.data > 0
  end, spec.name .. ' semantic tokens')
  local exercised = { 'definition', 'hover', 'completion', 'semantic tokens' }
  local unsupported = {}
  if client:supports_method('textDocument/references', bufnr) then
    request_until(client, 'textDocument/references', {
      textDocument = document, position = spec.definition, context = { includeDeclaration = true },
    }, function(result) return type(result) == 'table' and #result > 0 end, spec.name .. ' references')
    table.insert(exercised, 'references')
  else
    table.insert(unsupported, 'references')
  end
  if client:supports_method('textDocument/rename', bufnr) then
    local edit = request_until(client, 'textDocument/rename', {
      textDocument = document, position = spec.hover, newName = 'renamed_counter',
    }, function(result)
      return result and result ~= vim.NIL
        and (next(result.changes or {}) ~= nil or #(result.documentChanges or {}) > 0)
    end, spec.name .. ' rename workspace edits')
    -- Servers may return small insertion/deletion edits instead of replacing the
    -- complete identifier. Verify the resulting text, as the editor does.
    vim.lsp.util.apply_workspace_edit(edit, client.offset_encoding)
    assert(table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, true), '\n'):find('renamed_counter', 1, true),
      spec.name .. ' rename did not produce the requested identifier')
    api.nvim_buf_set_lines(bufnr, 0, -1, false, spec.lines)
    vim.cmd.write()
    table.insert(exercised, 'applied rename')
  else
    table.insert(unsupported, 'rename')
  end
  if client:supports_method('textDocument/inlayHint', bufnr) then
    local mapping = vim.fn.maparg(' th', 'n', false, true)
    assert(type(mapping.callback) == 'function', spec.name .. ' inlay toggle mapping is missing')
    vim.lsp.inlay_hint.enable(false, { bufnr = bufnr })
    mapping.callback()
    assert(vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr }), spec.name .. ' inlay toggle did not enable hints')
    request_until(client, 'textDocument/inlayHint', {
      textDocument = document,
      range = { start = { line = 0, character = 0 }, ['end'] = { line = #spec.lines - 1, character = #spec.lines[#spec.lines] } },
    }, function() return true end, spec.name .. ' inlay request')
    mapping.callback()
    assert(not vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr }), spec.name .. ' inlay toggle did not disable hints')
    table.insert(exercised, 'inlay toggle')
  else
    table.insert(unsupported, 'inlay hints')
  end

  -- Introduce an error only in the disposable fixture, then verify diagnostics
  -- arrive through Neovim's configured push/pull path rather than a mock client.
  local broken_line = spec.lines[spec.completion.line + 1]:gsub(spec.member, 'missing_identifier', 1)
  api.nvim_buf_set_lines(bufnr, spec.completion.line, spec.completion.line + 1, false, { broken_line })
  vim.cmd.write()
  local diagnostic
  assert(vim.wait(45000, function()
    for _, item in ipairs(vim.diagnostic.get(bufnr, { severity = vim.diagnostic.severity.ERROR })) do
      if item.message:find('missing_identifier', 1, true) then diagnostic = item; return true end
    end
    return false
  end, 100), spec.name .. ' did not report the deliberately missing member')
  table.insert(exercised, 'error diagnostics')

  if client:supports_method('textDocument/codeAction', bufnr) then
    local range = { start = { line = diagnostic.lnum, character = diagnostic.col },
      ['end'] = { line = diagnostic.end_lnum or diagnostic.lnum, character = diagnostic.end_col or diagnostic.col + 1 } }
    local lsp_diagnostic = diagnostic.user_data and diagnostic.user_data.lsp or {
      range = range, message = diagnostic.message, severity = diagnostic.severity,
    }
    -- Rust may answer ContentModified while its background check catches up;
    -- retry the protocol request against this unchanged buffer until it settles.
    local actions = request_until(client, 'textDocument/codeAction', {
      textDocument = document, range = range, context = { diagnostics = { lsp_diagnostic } },
    }, function() return true end, spec.name .. ' code action request')
    local count = type(actions) == 'table' and #actions or 0
    table.insert(exercised, 'code actions (' .. count .. ' offered)')
  else
    table.insert(unsupported, 'code actions')
  end
  print('PASS ' .. spec.name .. ': ' .. table.concat(exercised, ', '))
  if #unsupported > 0 then print('UNSUPPORTED ' .. spec.name .. ': ' .. table.concat(unsupported, ', ')) end
end

local function cpp()
  local root = vim.fs.joinpath(base, 'cpp')
  local definition_file = write(root, 'types.hpp', { '#pragma once', 'struct Counter { int value = 1; };' })
  local lines = { '#include "types.hpp"', 'int main() {', '    Counter counter{};', '    return counter.value;', '}' }
  write(root, 'compile_commands.json', vim.json.encode({ {
    directory = root,
    file = vim.fs.joinpath(root, 'main.cpp'),
    arguments = { vim.fn.exepath('clang++') ~= '' and vim.fn.exepath('clang++') or 'clang++', '-std=c++20', '-c', vim.fs.joinpath(root, 'main.cpp') },
  } }))
  check({ name = 'C++/clangd', server = 'clangd', root = root, file = 'main.cpp', lines = lines,
    definition = position(lines, 2, 'Counter'), definition_file = definition_file,
    hover = position(lines, 2, 'counter'), completion = position(lines, 3, 'counter.', true), member = 'value' })
end

local function rust()
  local root = vim.fs.joinpath(base, 'rust')
  write(root, 'Cargo.toml', { '[package]', 'name = "nvim_language_test"', 'version = "0.1.0"', 'edition = "2024"' })
  local definition_file = write(root, 'src/types.rs', { 'pub struct Counter { pub value: i32 }' })
  local lines = { 'mod types;', 'use types::Counter;', 'fn main() {', '    let counter = Counter { value: 1 };', '    let _ = counter.value;', '}' }
  check({ name = 'Rust/rust-analyzer', server = 'rust_analyzer', root = root, file = 'src/main.rs', lines = lines,
    definition = position(lines, 3, 'Counter'), definition_file = definition_file,
    hover = position(lines, 3, 'counter'), completion = position(lines, 4, 'counter.', true), member = 'value' })
end

local function cs()
  local root = vim.fs.joinpath(base, 'cs')
  local project = write(root, 'LanguageTest.csproj', {
    '<Project Sdk="Microsoft.NET.Sdk">', '<PropertyGroup>', '<TargetFramework>net10.0</TargetFramework>',
    '<OutputType>Exe</OutputType>', '<ImplicitUsings>enable</ImplicitUsings>', '<Nullable>enable</Nullable>',
    '</PropertyGroup>', '</Project>',
  })
  write(root, 'LanguageTest.sln', {
    'Microsoft Visual Studio Solution File, Format Version 12.00', '# Visual Studio Version 17',
    'Project("{9A19103F-16F7-4668-BE54-9A1E7A4F7556}") = "LanguageTest", "LanguageTest.csproj", "{02BF46AD-F579-4D89-9B9C-740CB1334522}"',
    'EndProject', 'Global', '  GlobalSection(SolutionConfigurationPlatforms) = preSolution',
    '    Debug|Any CPU = Debug|Any CPU', '  EndGlobalSection', '  GlobalSection(ProjectConfigurationPlatforms) = postSolution',
    '    {02BF46AD-F579-4D89-9B9C-740CB1334522}.Debug|Any CPU.ActiveCfg = Debug|Any CPU',
    '    {02BF46AD-F579-4D89-9B9C-740CB1334522}.Debug|Any CPU.Build.0 = Debug|Any CPU',
    '  EndGlobalSection', 'EndGlobal',
  })
  local definition_file = write(root, 'Counter.cs', { 'internal sealed class Counter { public int Value { get; set; } }' })
  local lines = { 'internal static class Program', '{', '    static void Main()', '    {',
    '        var counter = new Counter();', '        counter.Value = 1;', '    }', '}' }
  write(root, 'Program.cs', lines)
  local restore = vim.system({ 'dotnet', 'restore', project, '--ignore-failed-sources', '--nologo' }, { text = true }):wait(30000)
  assert(restore.code == 0, '.NET fixture restore failed: ' .. (restore.stderr or '') .. (restore.stdout or ''))
  check({ name = 'C#/Roslyn', server = 'roslyn', root = root, file = 'Program.cs', lines = lines,
    definition = position(lines, 4, 'Counter'), definition_file = definition_file,
    hover = position(lines, 4, 'counter'), completion = position(lines, 5, 'counter.', true), member = 'Value' })
end

local function jai()
  local root = vim.fs.joinpath(base, 'jai')
  write(root, 'jacket.toml', { '[project]', 'entry = ["main.jai"]', '[toolchain]', 'version = "0.30.4"' })
  local definition_file = write(root, 'types.jai', { 'Counter :: struct { value: s32; }' })
  local lines = { '#load "types.jai";', 'main :: () {', '    counter: Counter;', '    counter.value = 1;', '}' }
  check({ name = 'Jai/Jacket', server = 'jailsp', root = root, file = 'main.jai', lines = lines,
    definition = position(lines, 2, 'Counter'), definition_file = definition_file,
    hover = position(lines, 2, 'counter'), completion = position(lines, 3, 'counter.', true), member = 'value' })
end

vim.schedule(function()
  local ok, err = xpcall(function()
    if selected.cpp then cpp() end
    if selected.rust then rust() end
    if selected.cs then cs() end
    if selected.jai then jai() end
    print('PASS all selected language smoke tests; fixtures: ' .. base)
  end, debug.traceback)
  if not ok then
    api.nvim_err_writeln(err)
    vim.cmd('cquit 1')
  else
    vim.cmd('qa!')
  end
end)
