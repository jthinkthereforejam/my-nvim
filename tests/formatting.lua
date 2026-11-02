-- nvim --headless -i NONE -u ./init.lua -c "lua dofile('tests/formatting.lua')"
-- Real embedded keys, installed Jacket jaifmt/clangd, and disposable cache files.
assert(vim.g.my_nvim_ready, 'Load the my-nvim configuration before this test')
require('config.autosave').setup({ autosave = { enabled = false } })
local api, fn, uv = vim.api, vim.fn, vim.uv
local config_root = assert(vim.g.my_nvim_root)
local base = vim.fs.joinpath(fn.stdpath('cache'), 'my-nvim-formatting-tests', tostring(uv.os_getpid()) .. '-' .. tostring(uv.hrtime()))
local root = base .. "/项目 空格 &';$"
fn.mkdir(root, 'p')
local child
local function pause(ms) vim.wait(ms, function() return false end, 10) end
local function wait_for(predicate, message, timeout)
  assert(vim.wait(timeout or 10000, predicate, 15), message)
end
local function close(handle) if handle and not handle:is_closing() then handle:close() end end
local function write(path, lines)
  fn.mkdir(vim.fs.dirname(path), 'p')
  assert(fn.writefile(lines, path) == 0, 'Could not write disposable fixture')
  return path
end
local function same(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message .. ': ' .. vim.inspect({ expected = expected, actual = actual }))
end
local function spawn()
  fn.mkdir(base .. '/undo', 'p')
  local early = ('lua vim.g.my_nvim_root=%q; vim.opt.rtp:prepend(%q); local m=require("config.machine").load(); m.autosave={enabled=false}; m.deepseek={enabled=false}; m.project=vim.tbl_extend("force",m.project or {},{state_dir=%q}); vim.o.swapfile=false; vim.opt.undodir=%q')
    :format(config_root, config_root, base .. '/state', base .. '/undo')
  local environment, env = require('config.project_native').child_env(), {}
  for key, value in pairs(environment) do if key:upper() ~= 'DEEPSEEK_API_KEY' then env[#env + 1] = key .. '=' .. value end end
  local c = { stdin = uv.new_pipe(false), stdout = uv.new_pipe(false), stderr = uv.new_pipe(false), serial = 0, responses = {}, errors = {} }
  child = c
  c.handle, c.pid = uv.spawn(vim.v.progpath, {
    args = { '--embed', '-i', 'NONE', '--cmd', early, '-u', config_root .. '/init.lua' }, cwd = root,
    env = env, hide = true, stdio = { c.stdin, c.stdout, c.stderr },
  }, function(code, signal) c.exited = { code = code, signal = signal }; close(c.handle) end)
  assert(c.handle, c.pid)
  local unpacker = vim.mpack.Unpacker()
  c.stdout:read_start(function(err, data)
    if err then c.protocol_error = tostring(err) end
    if not data then return end
    local offset = 1
    while offset <= #data do
      local ok, message, next_offset = pcall(unpacker, data, offset)
      if not ok then c.protocol_error = tostring(message); return end
      offset = next_offset
      if message and message[1] == 1 then c.responses[message[2]] = message
      elseif message and message[1] == 0 then c.stdin:write(vim.mpack.encode({ 1, message[2], { 0, 'Unsupported test UI request' }, vim.NIL })) end
    end
  end)
  c.stderr:read_start(function(err, data) if err then c.errors[#c.errors + 1] = tostring(err) end; if data then c.errors[#c.errors + 1] = data end end)
  function c:request(method, args)
    self.serial = self.serial + 1
    local id = self.serial
    assert(not self.exited, 'Owned formatter UI exited: ' .. table.concat(self.errors))
    self.stdin:write(vim.mpack.encode({ 0, id, method, args or {} }))
    wait_for(function() return self.responses[id] or self.protocol_error or self.exited end, 'Formatter RPC timeout: ' .. method, 20000)
    assert(not self.protocol_error, self.protocol_error)
    local response = self.responses[id]; self.responses[id] = nil
    assert(response, 'Owned formatter UI exited during ' .. method .. ': ' .. table.concat(self.errors))
    assert(response[3] == nil or response[3] == vim.NIL, 'Formatter API error: ' .. vim.inspect(response[3]))
    return response[4]
  end
  function c:lua(source, args) return self:request('nvim_exec_lua', { source, args or {} }) end
  function c:input(keys) return self:request('nvim_input', { keys }) end
  function c:lines() return self:lua('return vim.api.nvim_buf_get_lines(0,0,-1,true)') end
  function c:open(name, lines, filetype)
    local path = write(root .. '/' .. name, lines)
    self:lua([[local path,ft=...; vim.cmd('edit '..vim.fn.fnameescape(path)); vim.b.completion=false; if ft then vim.bo.filetype=ft end]], { path, filetype })
    wait_for(function() return self:lua('return vim.api.nvim_get_mode().mode') == 'n' end, 'Fixture did not enter Normal mode')
    return path
  end
  function c:format(first, last)
    return self:lua([[local first,last=...; if first==vim.NIL then first=nil end; if last==vim.NIL then last=nil end; local ok,err=require('config.formatting').format(first and {first=first,last=last} or nil); return {ok=ok,error=err}]], { first or vim.NIL, last or vim.NIL })
  end
  function c:reset_notices() self:lua('_G.format_test_notices={}; vim.v.errmsg=""') end
  function c:notices() return self:lua('return _G.format_test_notices') end
  function c:undo(expected, formatted, label)
    self:input('u'); wait_for(function() return vim.deep_equal(self:lines(), expected) end, label .. ': one undo did not restore the complete pre-format text')
    self:input('<C-r>'); wait_for(function() return vim.deep_equal(self:lines(), formatted) end, label .. ': redo did not restore formatted text')
  end
  function c:shutdown()
    if not self.exited then
      pcall(self.lua, self, [[require('config.autosave').setup({autosave={enabled=false}}); for _,c in ipairs(vim.lsp.get_clients()) do c:stop(true) end]])
      pcall(self.stdin.write, self.stdin, vim.mpack.encode({ 2, 'nvim_command', { 'qa!' } }))
      vim.wait(5000, function() return self.exited ~= nil end, 10)
    end
    if not self.exited then pcall(self.handle.kill, self.handle, 15); vim.wait(3000, function() return self.exited ~= nil end, 10) end
    close(self.stdin); close(self.stdout); close(self.stderr); close(self.handle)
  end
  c:request('nvim_ui_attach', { 150, 45, { ext_linegrid = true, rgb = true } })
  wait_for(function() return c:lua('return vim.g.my_nvim_ready==true') end, 'Configuration did not initialize')
  c:lua([[
    _G.format_test_notices={}
    vim.notify=function(message,level) _G.format_test_notices[#_G.format_test_notices+1]={message=tostring(message),level=level} end
    vim.o.hidden=true
    require('config.project').activate(...,{restore=false,pick=false})
  ]], { root })
  return c
end
local jai_raw = { 'alpha :: () {', 'x:=1;', 'y:=2;', '}', '', 'beta :: () {', 'y:=3;', '}' }
local jai_full = { 'alpha :: () {', '    x := 1;', '    y := 2;', '}', '', 'beta :: () {', '    y := 3;', '}' }
local jai_part = vim.deepcopy(jai_full); jai_part[7] = jai_raw[7]
local function jai(c)
  local available = c:lua([[local f,err=require('jai.toolchain').find('jaifmt'); return {found=f~=nil,error=err}]])
  assert(available.found, 'Install the pinned Jacket toolchain before this suite: ' .. vim.inspect(available))
  write(root .. '/jacket.toml', { '[project]', 'entry = ["selected.jai"]', '[toolchain]', 'version = "0.30.4"', '[format]', 'ignore = ["ignored.jai"]' })
  c:open('selected.jai', jai_raw, 'jai')
  local range = c:format(2, 3); assert(range.ok, 'Jai range formatter failed: ' .. vim.inspect(range))
  same(c:lines(), jai_part, 'Jai selection changed lines outside the selected 2..3 range')
  c:undo(jai_raw, jai_part, 'Jai multi-line selection')
  c:open('visual.jai', jai_raw, 'jai'); c:input('2GVjgw')
  wait_for(function() return vim.deep_equal(c:lines(), jai_part) end, 'Visual gw did not format exactly the selected Jai lines')
  assert(c:lua('return vim.api.nvim_get_mode().mode') == 'n', 'Visual gw left selection active')
  c:undo(jai_raw, jai_part, 'Visual Jai gw')
  c:open('ex-range.jai', jai_raw, 'jai'); c:input(':2,3Format<CR>')
  wait_for(function() return vim.deep_equal(c:lines(), jai_part) end, ':2,3Format did not preserve unselected Jai code')
  c:open('whole.jai', jai_raw, 'jai'); c:input(':Format<CR>')
  wait_for(function() return vim.deep_equal(c:lines(), jai_full) end, ':Format did not format the complete Jai file')
  c:undo(jai_raw, jai_full, 'Whole Jai :Format')
  local single = vim.deepcopy(jai_raw); single[3] = jai_full[3]
  local single_expected = vim.deepcopy(single); single_expected[2] = jai_full[2]
  c:open('line.jai', single, 'jai'); c:input('2Ggww')
  wait_for(function() return vim.deep_equal(c:lines(), single_expected) end, 'gww/operatorfunc did not format the current Jai line')
  same(c:lua('return vim.api.nvim_win_get_cursor(0)'), { 2, 0 }, 'gww moved the original cursor')
  c:undo(single, single_expected, 'Jai gww')
  c:open('paragraph.jai', jai_raw, 'jai'); c:input('2Ggwap')
  wait_for(function() return vim.deep_equal(c:lines(), jai_part) end, 'gwap did not format only the first Jai paragraph')
  c:open('to-end.jai', jai_raw, 'jai'); c:input('2GgwG')
  wait_for(function() return vim.deep_equal(c:lines(), jai_full) end, 'gwG did not format from the current line to EOF')
  c:open('boundary.jai', jai_raw, 'jai'); c:reset_notices()
  local boundary = c:format(2, 2)
  assert(not boundary.ok and boundary.error:find('expand the selection', 1, true), 'Jai cross-boundary hunk was not explicitly rejected')
  same(c:lines(), jai_raw, 'Cross-boundary rejection applied a partial edit')
  c:open('ignored.jai', jai_raw, 'jai'); c:reset_notices()
  local ignored = c:format(2, 3)
  assert(not ignored.ok and ignored.error:find('ignore', 1, true), 'Jacket [format].ignore was bypassed')
  same(c:lines(), jai_raw, 'Ignored Jai buffer was changed')
  local broken = { 'main :: () {', 'x:=1;' }
  c:open('broken.jai', broken, 'jai'); c:reset_notices()
  local error_result = c:format(1, 2)
  assert(not error_result.ok and error_result.error:find('jaifmt', 1, true), 'Broken Jai did not report the real formatter error')
  same(c:lines(), broken, 'jaifmt failure changed buffer contents')
  print('PASS formatting Jai: real jaifmt selection/Visual/Ex/motions, whole-file, one-step undo/redo, Unicode/spaces, ignore/error/cross-boundary refusal')
end
local function no_lsp(c)
  local text = { string.rep('plain prose ', 20), string.rep('second line ', 18) }
  c:open('no-lsp.txt', text, 'text'); c:lua('vim.bo.textwidth=20'); c:reset_notices(); c:input('gwap')
  wait_for(function() return #c:notices() > 0 end, 'No-LSP gw did not explain why formatting was unavailable')
  same(c:lines(), text, 'No-LSP gw fell back to native text reflow')
  local notices = c:notices()
  assert(notices[#notices].message:find('No attached LSP', 1, true), 'No-LSP error was not actionable: ' .. vim.inspect(notices))
  assert(c:lua('return vim.api.nvim_get_mode().mode') == 'n', 'Unavailable formatter left operator mode active')
  -- A real Neovim LSP client with a controlled in-process transport. It only
  -- advertises whole-file formatting; a range must never call that method.
  c:open('whole-only.format-fixture', { 'unformatted text' }, 'format_fixture')
  c:lua([[
    _G.format_test_whole_requests=0
    _G.format_test_client=vim.lsp.start({name='format_test_whole_only',root_dir=vim.fn.getcwd(),cmd=function()
      local closed,serial=false,0
      return {
        request=function(method,params,callback)
          serial=serial+1
          vim.schedule(function()
            if method=='initialize' then callback(nil,{capabilities={textDocumentSync=1,documentFormattingProvider=true,documentRangeFormattingProvider=false}})
            elseif method=='textDocument/formatting' then _G.format_test_whole_requests=_G.format_test_whole_requests+1; callback(nil,{})
            else callback(nil,nil) end
          end)
          return true,serial
        end,
        notify=function() return true end,is_closing=function() return closed end,terminate=function() closed=true end,
      }
    end})
  ]])
  wait_for(function() return c:lua([[local c=vim.lsp.get_client_by_id(_G.format_test_client); return c and c.initialized]]) end, 'Whole-file-only LSP fixture did not initialize')
  local only = c:format(1, 1)
  assert(not only.ok and only.error:find('selection formatting',1,true), 'A whole-file-only server was accepted for selection formatting')
  assert(c:lua('return _G.format_test_whole_requests') == 0, 'Range formatting silently fell back to the whole-file LSP method')
  same(c:lines(), { 'unformatted text' }, 'Unsupported LSP range changed buffer text')
  assert(c:format().ok and c:lua('return _G.format_test_whole_requests') == 1, 'Whole-file-only test server was not actually available to :Format')
  c:lua([[vim.lsp.get_client_by_id(_G.format_test_client):stop(true)]])
  local boundary_lines = { 'before', 'selected', 'outside' }
  c:open('unsafe-boundary.format-fixture', boundary_lines, 'format_fixture')
  c:lua([[
    _G.format_test_client=vim.lsp.start({name='format_test_bad_boundary',root_dir=vim.fn.getcwd(),cmd=function()
      local closed,serial=false,0
      return {
        request=function(method,params,callback)
          serial=serial+1
          vim.schedule(function()
            if method=='initialize' then callback(nil,{capabilities={textDocumentSync=1,documentRangeFormattingProvider=true}})
            elseif method=='textDocument/rangeFormatting' then callback(nil,{{range={start={line=1,character=0},['end']={line=2,character=0}},newText='changed'}})
            else callback(nil,nil) end
          end)
          return true,serial
        end,
        notify=function() return true end,is_closing=function() return closed end,terminate=function() closed=true end,
      }
    end})
  ]])
  wait_for(function() return c:lua([[local c=vim.lsp.get_client_by_id(_G.format_test_client); return c and c.initialized]]) end, 'Boundary LSP fixture did not initialize')
  local boundary = c:format(2, 2)
  assert(not boundary.ok and boundary.error:find('expand the selection',1,true), 'An LSP edit joined the selected line with the unselected next line')
  same(c:lines(), boundary_lines, 'LSP boundary refusal modified or merged unselected code')
  c:lua([[vim.lsp.get_client_by_id(_G.format_test_client):stop(true)]])
  print('PASS formatting no-LSP/whole-only: actionable notice, no text wrapping or whole-file selection fallback; unsafe LSP newline merge refused')
end
local function cpp(c)
  write(root .. '/compile_flags.txt', { '-std=c++20' })
  write(root .. '/.clang-format', { 'BasedOnStyle: LLVM', 'IndentWidth: 4', 'ColumnLimit: 100' })
  local raw = { 'int alpha() {', 'int x=1;', 'return x;', '}', '', 'int beta(){return 2;}' }
  local path = c:open('clangd 代码.cpp', raw, 'cpp')
  wait_for(function() return c:lua([[for _,c in ipairs(vim.lsp.get_clients({bufnr=0,name='clangd'})) do if c.initialized and c:supports_method('textDocument/rangeFormatting',0) then return true end end; return false]]) end, 'Real clangd range formatter did not attach', 45000)
  local result = c:format(2, 3); assert(result.ok, 'Real clangd selection failed: ' .. vim.inspect(result))
  local selected = c:lines()
  assert(not vim.deep_equal(selected, raw), 'clangd selection made no code-formatting changes')
  same({ selected[1], selected[4], selected[5], selected[6] }, { raw[1], raw[4], raw[5], raw[6] }, 'clangd selection changed unselected code')
  assert(selected[2]:find('    int x = 1;', 1, true) and selected[3]:find('    return x;', 1, true), 'clangd selection did not apply real indentation/operator spacing')
  c:undo(raw, selected, 'clangd selection')
  c:input(':Format<CR>')
  wait_for(function() local lines=c:lines(); return not vim.deep_equal(lines,selected) and table.concat(lines,'\n'):find('int beta()',1,true)~=nil end, 'clangd whole-file :Format did not change the unselected function')
  local full = c:lines()
  c:undo(selected, full, 'clangd whole-file :Format')
  same(fn.readfile(path), raw, 'Explicit formatting wrote to disk before autosave was enabled')
  local auto_raw = { 'int gamma(){return 3;}' }
  local auto_path = c:open('autosave 代码.cpp', auto_raw, 'cpp')
  wait_for(function() return c:lua([[for _,c in ipairs(vim.lsp.get_clients({bufnr=0,name='clangd'})) do if c.initialized then return true end end; return false]]) end, 'clangd did not attach to autosave fixture')
  c:lua([[require('config.autosave').setup({autosave={enabled=true,delay_ms=1000}})]])
  local timed = c:format(); assert(timed.ok, 'Autosave-format fixture failed: ' .. vim.inspect(timed))
  local formatted = c:lines(); assert(not vim.deep_equal(formatted, auto_raw), 'Autosave-format fixture did not change')
  same(fn.readfile(auto_path), auto_raw, 'Formatting saved synchronously')
  pause(600); same(fn.readfile(auto_path), auto_raw, 'Formatting bypassed the configured autosave delay')
  wait_for(function() return vim.deep_equal(fn.readfile(auto_path), formatted) end, 'Formatted text did not autosave after its debounce delay', 4000)
  assert(not c:lua('return vim.bo.modified'), 'Autosaved formatted buffer stayed modified')
  c:lua([[require('config.autosave').setup({autosave={enabled=false}})]])
  print('PASS formatting clangd: real selected/whole-file formatting, undo/redo, delayed autosave without synchronous writes')
end
local function run()
  assert(vim.system({ 'git', 'init', '--quiet', root }, { text = true }):wait(10000).code == 0)
  local c = spawn()
  assert(c:lua([[return vim.fn.exists(':Format')==2 and type(vim.fn.maparg('gw','n',false,true).callback)=='function' and type(vim.fn.maparg('gw','x',false,true).callback)=='function']]), 'Format command/gw mappings are not installed')
  jai(c); no_lsp(c); cpp(c)
end
vim.schedule(function()
  local ok, err = xpcall(run, debug.traceback)
  if child then pcall(child.shutdown, child); if ok and (not child.exited or child.exited.code ~= 0) then ok, err = false, 'Owned formatter UI did not exit cleanly' end end
  if ok then print('PASS all formatting integration scenarios; fixtures: ' .. base); vim.cmd('qa!')
  else api.nvim_err_writeln(err); vim.cmd('cquit 1') end
end)
