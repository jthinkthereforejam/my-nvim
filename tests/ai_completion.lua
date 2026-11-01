-- nvim --headless -u ./init.lua -c "lua dofile('tests/ai_completion.lua')"
-- Requires Python 3; MY_NVIM_TEST_PYTHON may name its executable.
-- All HTTP traffic targets a local mock; Minuet/curl/rendering run unmodified.
assert(vim.g.my_nvim_ready, 'Load the my-nvim configuration before this test')
local H = {}
local api, fn, uv = vim.api, vim.fn, vim.uv
local config_root = assert(vim.g.my_nvim_root)
local function close(handle) if handle and not handle:is_closing() then handle:close() end end
local function env_list(env) local result = {}; for k, v in pairs(env) do result[#result + 1] = k .. '=' .. v end; return result end
function H.pause(ms) vim.wait(ms, function() return false end, 10) end
function H.wait(predicate, message, timeout) assert(vim.wait(timeout or 10000, predicate, 15), message) end
local function decode_lines(path)
  local result = {}
  if fn.filereadable(path) == 0 then return result end
  for _, line in ipairs(fn.readfile(path)) do local ok, item = pcall(vim.json.decode, line); if ok then result[#result + 1] = item end end
  return result
end
function H.environment(label)
  local test = { base = vim.fs.joinpath(fn.stdpath('cache'), 'my-nvim-ai-tests', label .. '-' .. uv.os_getpid()), clients = {} }
  fn.mkdir(test.base, 'p')
  test.server_dir = vim.fs.joinpath(test.base, 'server'); fn.mkdir(test.server_dir, 'p')
  function test:control(value)
    local target = vim.fs.joinpath(self.server_dir, 'control.json')
    local temp = target .. '.tmp'
    fn.writefile({ vim.json.encode(vim.tbl_extend('force', { mode = 'success', completion = 'AI_FIXTURE_RESULT', delay = 0 }, value or {})) }, temp)
    assert(uv.fs_rename(temp, target))
  end
  function test:events() return decode_lines(vim.fs.joinpath(self.server_dir, 'events.jsonl')) end
  function test:requests()
    local result = {}; for _, item in ipairs(self:events()) do if item.event == 'request' then result[#result + 1] = item end end; return result
  end
  function test:count() return #self:requests() end
  function test:disconnected(id)
    for _, item in ipairs(self:events()) do if item.id == id and item.event == 'disconnect' then return true end end
    return false
  end
  test:control()
  local python = vim.env.MY_NVIM_TEST_PYTHON or fn.exepath('python3')
  if not python or python == '' then python = fn.exepath('python') end
  assert(python and python ~= '', 'Python 3 is required; set MY_NVIM_TEST_PYTHON')
  test.server = vim.system({ python, '-u', vim.fs.joinpath(config_root, 'tests/ai_completion_mock.py'), '--root', test.server_dir }, { text = true })
  H.wait(function() return fn.filereadable(vim.fs.joinpath(test.server_dir, 'ready.json')) == 1 end, 'Local HTTP fixture did not start; check MY_NVIM_TEST_PYTHON', 15000)
  local ready = vim.json.decode(table.concat(fn.readfile(vim.fs.joinpath(test.server_dir, 'ready.json')), '\n'))
  test.endpoint = 'http://127.0.0.1:' .. ready.port .. '/completions'
  function test:client(settings)
    settings = settings or {}
    local index = #self.clients + 1
    local data = { enabled = settings.enabled ~= false, endpoint = self.endpoint, model = 'deepseek-flash' }
    if settings.local_key ~= nil then data.api_key = settings.local_key end
    local state_dir = vim.fs.joinpath(self.base, 'state-' .. index)
    local early = ('lua vim.g.my_nvim_root=%q; vim.opt.rtp:prepend(%q); local m=require("config.machine").load(); m.project=vim.tbl_extend("force",m.project or {},{state_dir=%q}); m.deepseek=vim.json.decode(%q); vim.g.ai_test_notices={}; local notify=vim.notify; vim.notify=function(msg,level,opts) local t=vim.g.ai_test_notices; t[#t+1]={message=tostring(msg),level=level}; vim.g.ai_test_notices=t; return notify(msg,level,opts) end')
      :format(config_root, config_root, state_dir, vim.json.encode(data))
    if settings.no_curl then
      early = early .. '; local executable=vim.fn.executable; vim.fn.executable=function(cmd) if cmd=="curl" or cmd=="curl.exe" then return 0 end; return executable(cmd) end'
    end
    local child_env = require('config.project_native').child_env()
    -- Windows environment names are case-insensitive. Remove every inherited
    -- spelling before supplying this scenario's synthetic credential.
    for key in pairs(child_env) do if key:upper() == 'DEEPSEEK_API_KEY' then child_env[key] = nil end end
    child_env.DEEPSEEK_API_KEY = settings.env_key
    child_env.NO_PROXY, child_env.no_proxy = '127.0.0.1,localhost', '127.0.0.1,localhost'
    local client = { stdin = uv.new_pipe(false), stdout = uv.new_pipe(false), stderr = uv.new_pipe(false), responses = {}, serial = 0, errors = {}, test = self, index = index }
    self.clients[#self.clients + 1] = client
    client.handle = assert(uv.spawn(vim.v.progpath, { args = { '--embed', '-i', 'NONE', '--cmd', early, '-u', vim.fs.joinpath(config_root, 'init.lua') },
      cwd = self.base, env = env_list(child_env), hide = true, stdio = { client.stdin, client.stdout, client.stderr } }, function(code, signal)
      client.exited = { code = code, signal = signal }; close(client.handle)
    end))
    local unpack = vim.mpack.Unpacker()
    client.stdout:read_start(function(err, chunk)
      if err then client.protocol_error = tostring(err) end
      if not chunk then return end
      local position = 1
      while position <= #chunk do
        local ok, message, next_position = pcall(unpack, chunk, position)
        if not ok then client.protocol_error = tostring(message); return end
        position = next_position
        if message and message[1] == 1 then client.responses[message[2]] = message
        elseif message and message[1] == 0 then client.stdin:write(vim.mpack.encode({ 1, message[2], { 0, 'Unsupported test UI request' }, vim.NIL })) end
      end
    end)
    client.stderr:read_start(function(err, chunk) if err then client.errors[#client.errors + 1] = tostring(err) end; if chunk then client.errors[#client.errors + 1] = chunk end end)
    function client:request(method, args)
      self.serial = self.serial + 1; local id = self.serial
      assert(not self.exited, 'Embedded Neovim exited: ' .. table.concat(self.errors))
      self.stdin:write(vim.mpack.encode({ 0, id, method, args or {} }))
      H.wait(function() return self.responses[id] or self.exited or self.protocol_error end, 'Embedded RPC timed out: ' .. method, 20000)
      assert(not self.protocol_error, self.protocol_error)
      local response = self.responses[id]
      assert(response, 'Embedded Neovim exited during ' .. method .. ': ' .. table.concat(self.errors))
      self.responses[id] = nil
      assert(response[3] == nil or response[3] == vim.NIL, 'Embedded API error: ' .. vim.inspect(response[3]))
      return response[4]
    end
    function client:lua(code, args) return self:request('nvim_exec_lua', { code, args or {} }) end
    function client:input(keys) return self:request('nvim_input', { keys }) end
    function client:status() return self:lua("return require('config.ai_completion').status()") end
    function client:inspect()
      return self:lua([[
        local buf=vim.api.nvim_get_current_buf(); local ns=vim.api.nvim_get_namespaces()['minuet.virtualtext']; local text={}
        if ns then for _,mark in ipairs(vim.api.nvim_buf_get_extmarks(buf,ns,0,-1,{details=true})) do
          for _,chunk in ipairs(mark[4].virt_text or {}) do text[#text+1]=chunk[1] end
          for _,line in ipairs(mark[4].virt_lines or {}) do for _,chunk in ipairs(line) do text[#text+1]=chunk[1] end end
        end end
        return {buf=buf,win=vim.api.nvim_get_current_win(),mode=vim.api.nvim_get_mode().mode,
          lines=vim.api.nvim_buf_get_lines(buf,0,-1,true),cursor=vim.api.nvim_win_get_cursor(0),ghost=table.concat(text,'\n'),
          status=require('config.ai_completion').status(),notices=vim.g.ai_test_notices or {}}
      ]])
    end
    function client:edit(name, lines, cursor, kind, insert)
      local file = vim.fs.joinpath(self.test.base, 'files-' .. self.index, name or 'fixture.txt')
      fn.mkdir(vim.fs.dirname(file), 'p')
      if name then fn.writefile(lines or { 'prefix TAIL' }, file) end
      self:lua([[
        local file,lines,cursor,kind=...; vim.cmd.stopinsert(); require('config.ai_completion').dismiss();
        if file=='' then vim.cmd('enew!') else vim.cmd('edit! '..vim.fn.fnameescape(file)) end
        vim.bo.modifiable=true; vim.bo.readonly=false; vim.bo.buftype=''; vim.api.nvim_buf_set_lines(0,0,-1,false,lines)
        vim.api.nvim_win_set_cursor(0,cursor)
        if kind=='nofile' then vim.bo.buftype='nofile' elseif kind=='readonly' then vim.bo.readonly=true end
      ]], { name and file or '', lines or { 'prefix TAIL' }, cursor or { 1, 7 }, kind or '' })
      if insert ~= false then
        self:input('i')
        H.wait(function() return self:inspect().mode:sub(1,1) == 'i' end, 'Fixture did not enter insert mode')
        H.pause(60)
        self:lua("require('blink.cmp').hide()")
        if kind == 'nonmodifiable' then self:lua('vim.bo.modifiable=false') end
      end
      return file
    end
    function client:ghost(expected)
      H.wait(function() local view=self:inspect(); return view.status.visible and view.ghost:find(expected,1,true) ~= nil end,
        'Real Minuet virtual text did not render: ' .. expected, 10000)
      return self:inspect()
    end
    function client:shutdown()
      if not self.exited then
        pcall(self.lua,self,"require('config.ai_completion').dismiss()")
        pcall(self.stdin.write,self.stdin,vim.mpack.encode({2,'nvim_command',{'qa!'}}))
        vim.wait(5000,function() return self.exited~=nil end,10)
      end
      if not self.exited then pcall(self.handle.kill,self.handle,15); vim.wait(3000,function() return self.exited~=nil end,10) end
      close(self.stdin); close(self.stdout); close(self.stderr); close(self.handle)
    end
    client:request('nvim_ui_attach', { 120, 40, { ext_linegrid = true, rgb = true } })
    H.wait(function() return client:lua('return vim.g.my_nvim_ready==true') end, 'Child configuration did not initialize')
    return client
  end
  function test:cleanup()
    for _, client in ipairs(self.clients) do pcall(client.shutdown,client) end
    if self.server then pcall(self.server.kill,self.server,15); pcall(self.server.wait,self.server,5000) end
  end
  return test
end
function H.trigger(test, client, completion, control)
  test:control(vim.tbl_extend('force', { completion = completion }, control or {}))
  local before = test:count()
  assert(client:lua("return require('config.ai_completion').trigger()"), 'AI trigger was rejected for an eligible insert buffer')
  H.wait(function() return test:count() == before + 1 end, 'Minuet did not make the expected local HTTP request')
  return test:requests()[before + 1]
end
function H.assert_private(client)
  local view = client:inspect()
  local output = vim.inspect({ status=view.status,notices=view.notices }) .. client:lua("return vim.api.nvim_exec2('messages',{output=true}).output")
  for _, forbidden in ipairs({ 'LOCAL_FAKE_KEY', 'ENV_FAKE_KEY', 'PRIVATE_RESPONSE_SHOULD_NOT_LEAK', 'INVALID_RESPONSE_BODY_SHOULD_NOT_LEAK', 'PRIVATE_CONTEXT_MARKER' }) do
    assert(not output:find(forbidden,1,true), 'AI status/notifications exposed credentials, response text or source')
  end
end
if vim.g.my_nvim_ai_test_library then return H end

local test
local function run()
  test = H.environment('completion')
  local subset = vim.env.MY_NVIM_AI_TEST_CASE
  if not subset or subset == 'basic' then
    local client = test:client({ env_key='ENV_FAKE_KEY',local_key='LOCAL_FAKE_KEY' })
    assert(client:status().enabled and client:status().available, 'DeepSeek fixture did not become available')
    client:edit('basic.txt',{ 'private_prefix TAIL' },{1,15})
    local body_before = client:inspect().lines
    local request = H.trigger(test,client,'AI_SIMPLE_RESULT')
    assert(request.authorization=='Bearer ENV_FAKE_KEY', 'Environment key did not override the local key')
    assert(request.body.stream==false and request.body.max_tokens==256 and request.body.model=='deepseek-flash', 'FIM request limits/model differ from configuration')
    local view = client:ghost('AI_SIMPLE_RESULT')
    assert(vim.deep_equal(view.lines,body_before), 'A ghost completion modified the buffer before acceptance')
    assert(client:lua("return require('config.ai_completion').accept()"), 'Visible AI completion was not accepted')
    H.wait(function() return table.concat(client:inspect().lines,'\n'):find('AI_SIMPLE_RESULT',1,true) ~= nil end, 'Accept did not insert the real completion')
    H.assert_private(client)
    client:shutdown()
    print('PASS AI basic: real Minuet HTTP/virtual text, environment key priority, one candidate, bounded tokens, explicit acceptance')
  end
  if subset then return end

  for _, settings in ipairs({ {}, {local_key=''}, {env_key='ENV_FAKE_KEY',enabled=false}, {env_key='ENV_FAKE_KEY',no_curl=true} }) do
    local before=test:count(); local client=test:client(settings)
    client:edit('disabled.txt',{'prefix TAIL'},{1,7})
    assert(not client:status().enabled, 'An unavailable/disabled configuration enabled AI')
    assert(not client:lua("return require('config.ai_completion').trigger()"), 'Unavailable AI accepted a request')
    H.pause(1100); assert(test:count()==before,'An unavailable/disabled configuration sent an HTTP request')
    H.assert_private(client); client:shutdown()
  end
  local fallback=test:client({env_key='  ',local_key='LOCAL_FAKE_KEY'})
  fallback:edit('fallback.txt',{'prefix TAIL'},{1,7})
  local fallback_request=H.trigger(test,fallback,'AI_FALLBACK_RESULT')
  assert(fallback_request.authorization=='Bearer LOCAL_FAKE_KEY','Blank environment did not fall back to the local key')
  fallback:ghost('AI_FALLBACK_RESULT'); fallback:shutdown()
  print('PASS AI availability: absent/empty key, disabled option and missing curl send zero requests; blank env falls back locally')

  local guarded=test:client({env_key='ENV_FAKE_KEY'})
  for _, case in ipairs({ {'local.lua'}, {'.env'}, {'.env.local'}, {'readonly.txt','readonly'}, {'scratch.txt','nofile'}, {false}, {'nonmodifiable.txt','nonmodifiable'} }) do
    local before=test:count(); guarded:edit(case[1] or nil,{'prefix TAIL'},{1,7},case[2])
    assert(not guarded:lua("return require('config.ai_completion').trigger()"),'A protected buffer accepted an AI request')
    H.pause(1000); assert(test:count()==before,'A protected buffer sent source to HTTP')
  end
  guarded:shutdown()
  print('PASS AI buffer guards: sensitive files, unnamed/nofile/readonly/nonmodifiable buffers send zero requests')

  local unicode=test:client({env_key='ENV_FAKE_KEY'})
  local prefix,suffix=string.rep('甲',6100)..'PRE_END','SUFFIX_START'..string.rep('乙',2100)
  unicode:edit('unicode.txt',{prefix..suffix},{1,#prefix})
  local wire=H.trigger(test,unicode,'AI_UNICODE_RESULT')
  assert(fn.strchars(wire.body.prompt)==6000 and fn.strchars(wire.body.suffix)==2000,'Context limits are not Unicode character counts')
  assert(wire.body.prompt:sub(-7)=='PRE_END' and wire.body.suffix:sub(1,12)=='SUFFIX_START','Context was not taken adjacent to the cursor')
  unicode:ghost('AI_UNICODE_RESULT'); unicode:shutdown()
  print('PASS AI context: exact 6000/2000 Unicode-character prefix/suffix bounds')

  local debounce=test:client({env_key='ENV_FAKE_KEY'})
  test:control({completion='AI_DEBOUNCE_RESULT'})
  debounce:edit('debounce.txt',{'prefix TAIL'},{1,7})
  local start=test:count(); debounce:input('x'); H.pause(300); debounce:input('y'); H.pause(500)
  assert(test:count()==start,'AI requested before the 800ms debounce after the last edit')
  H.wait(function() return test:count()==start+1 end,'Debounced typing did not send exactly one request',2500)
  debounce:ghost('AI_DEBOUNCE_RESULT'); H.pause(200); assert(test:count()==start+1,'Debounced typing sent duplicate requests')
  debounce:shutdown()
  print('PASS AI debounce: continued typing resets the real 800ms request timer')

  for _, action in ipairs({'escape','edit','buffer','window','cursor','dismiss'}) do
    local client=test:client({env_key='ENV_FAKE_KEY'})
    client:edit('accept-race-'..action..'.txt',{'prefix TAIL'},{1,7})
    H.trigger(test,client,'AI_RACE_'..action); client:ghost('AI_RACE_'..action)
    local before=client:inspect()
    local code = ({ escape="vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>',true,false,true),'mx',false); assert(vim.fn.mode()=='n')", edit="vim.api.nvim_buf_set_lines(0,0,1,false,{'RACE_USER_EDIT'})",
      buffer="vim.cmd('enew!')", window="vim.cmd.vsplit()", cursor="vim.api.nvim_win_set_cursor(0,{1,0})", dismiss="a.dismiss()" })[action]
    assert(client:lua("local a=require('config.ai_completion'); local accepted=a.accept(); "..code..'; return accepted'),'Race fixture did not queue an acceptance')
    H.pause(120)
    local result=client:lua('local b=...; return vim.api.nvim_buf_get_lines(b,0,-1,true)',{before.buf})
    assert(not table.concat(result,'\n'):find('AI_RACE_',1,true),'Queued acceptance inserted into a stale '..action..' context')
    client:shutdown()
  end
  print('PASS AI accept races: mode, tick, buffer, window, cursor and generation rechecked before scheduled insertion')

  for _, action in ipairs({'typing','escape','buffer','window','dismiss','disable'}) do
    local client=test:client({env_key='ENV_FAKE_KEY'})
    client:edit('cancel-'..action..'.txt',{'prefix TAIL'},{1,7})
    local request=H.trigger(test,client,'AI_STALE_RESULT',{delay=2})
    if action=='typing' then client:input('x'); H.pause(60); client:lua("require('config.ai_completion').dismiss()")
    elseif action=='escape' then client:input('<Esc>')
    elseif action=='buffer' then client:lua("vim.cmd('enew!')")
    elseif action=='window' then client:lua('vim.cmd.vsplit()'); client:lua("require('config.ai_completion').dismiss()")
    elseif action=='dismiss' then client:lua("require('config.ai_completion').dismiss()")
    else client:lua("require('config.ai_completion').toggle()") end
    H.wait(function() return test:disconnected(request.id) end,'Old curl request was not cancelled after '..action,1800)
    assert(not client:status().pending and not client:status().visible,'A cancelled request remained pending/visible')
    client:shutdown()
  end
  print('PASS AI cancellation: actual HTTP clients disconnect on editing/leaving/switching/dismissing/disabling')

  local failure=test:client({env_key='ENV_FAKE_KEY'})
  failure:edit('errors.txt',{'PRIVATE_CONTEXT_MARKER TAIL'},{1,22})
  for _, mode in ipairs({'401','401','429','500','invalid'}) do
    local before=test:count(); H.trigger(test,failure,'unused',{mode=mode})
    H.wait(function() return not failure:status().pending end,'Failed HTTP request never settled')
    H.pause(1000); assert(test:count()==before+1,'A failed API request retried automatically')
    assert(not failure:status().visible,'An API error appeared as a completion')
    H.assert_private(failure)
  end
  local notices=failure:inspect().notices; local errors=0
  for _, item in ipairs(notices) do if item.message:find('DeepSeek:',1,true) then errors=errors+1 end end
  assert(errors<=1,'Repeated API errors were not notification-throttled')
  failure:shutdown()
  local timeout=test:client({env_key='ENV_FAKE_KEY'})
  timeout:edit('timeout.txt',{'prefix TAIL'},{1,7})
  local started=uv.hrtime(); local delayed=H.trigger(test,timeout,'AI_TOO_LATE',{delay=7})
  H.wait(function() return not timeout:status().pending end,'The five-second hard timeout did not fire',6500)
  local elapsed=(uv.hrtime()-started)/1e9
  assert(elapsed>=4.5 and elapsed<6.5,'HTTP hard timeout was outside its five-second budget')
  H.wait(function() return test:disconnected(delayed.id) end,'Timeout did not cancel the HTTP process',1500)
  assert(not timeout:status().visible,'Timed-out response became visible')
  H.assert_private(timeout); timeout:shutdown()
  print('PASS AI errors: sanitized/throttled 401/429/500/invalid responses, no automatic retries, five-second cancellation')

  local command=test:client({env_key='ENV_FAKE_KEY'})
  command:edit('command.txt',{'prefix TAIL'},{1,7},nil,false)
  test:control({completion='AI_COMMAND_RESULT'})
  command:request('nvim_command',{'AICompletionTrigger'})
  command:ghost('AI_COMMAND_RESULT'); command:shutdown()
  print('PASS AICompletionTrigger: normal-mode Ex command enters insert mode and requests a real completion')
end
vim.schedule(function()
  local ok,err=xpcall(run,debug.traceback)
  if test then test:cleanup() end
  if not ok then api.nvim_err_writeln(err); vim.cmd('cquit 1') else print('PASS all AI completion integration scenarios'); vim.cmd('qa!') end
end)
