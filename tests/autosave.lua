-- nvim --headless -u ./init.lua -c "lua dofile('tests/autosave.lua')"
-- Independent embedded UI, real disk files and normal Neovim write hooks.
-- No Python/API service; all fixture files, state and undo files stay in cache.
assert(vim.g.my_nvim_ready,'Load the my-nvim configuration before this test')
local api,fn,uv=vim.api,vim.fn,vim.uv
local config_root=assert(vim.g.my_nvim_root)
local base=vim.fs.joinpath(fn.stdpath('cache'),'my-nvim-autosave-tests',tostring(uv.os_getpid()))
local children={}
fn.mkdir(base,'p')
local function close(h) if h and not h:is_closing() then h:close() end end
local function pause(ms) vim.wait(ms,function() return false end,10) end
local function wait_for(predicate,message,timeout) assert(vim.wait(timeout or 5000,predicate,15),message) end
local function env_list(env) local result={}; for k,v in pairs(env) do result[#result+1]=k..'='..v end; return result end
local function disk(path) return fn.filereadable(path)==1 and fn.readfile(path) or nil end
local function same_disk(path,lines) return vim.deep_equal(disk(path),lines) end
local function spawn(enabled)
  local index=#children+1
  local root=vim.fs.joinpath(base,'child-'..index); fn.mkdir(root,'p'); fn.mkdir(root..'/undo','p')
  local shell=fn.has('win32')==1 and {'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-Command','[Threading.Thread]::Sleep(120000)'} or {'/bin/sleep','120'}
  local early=('lua vim.g.my_nvim_root=%q; vim.opt.rtp:prepend(%q); local m=require("config.machine").load(); m.project=vim.tbl_extend("force",m.project or {},{state_dir=%q}); m.deepseek={enabled=false}; m.autosave=vim.json.decode(%q); m.terminal={shell=vim.json.decode(%q)}; vim.o.swapfile=false; vim.opt.undodir=%q; vim.g.autosave_test_notices={}; local notify=vim.notify; vim.notify=function(msg,level,opts) local t=vim.g.autosave_test_notices; t[#t+1]={message=tostring(msg),level=level}; vim.g.autosave_test_notices=t; return notify(msg,level,opts) end')
    :format(config_root,config_root,root..'/state',vim.json.encode(enabled==nil and {} or {enabled=enabled,delay_ms=1000}),vim.json.encode(shell),root..'/undo')
  local env=require('config.project_native').child_env()
  for key in pairs(env) do if key:upper()=='DEEPSEEK_API_KEY' then env[key]=nil end end
  local c={root=root,stdin=uv.new_pipe(false),stdout=uv.new_pipe(false),stderr=uv.new_pipe(false),responses={},serial=0,errors={}}
  children[#children+1]=c
  c.handle,c.pid=uv.spawn(vim.v.progpath,{args={'--embed','-i','NONE','--cmd',early,'-u',config_root..'/init.lua'},
    cwd=root,env=env_list(env),hide=true,stdio={c.stdin,c.stdout,c.stderr}},function(code,signal) c.exited={code=code,signal=signal}; close(c.handle) end)
  assert(c.handle,c.pid)
  local unpack=vim.mpack.Unpacker()
  c.stdout:read_start(function(err,data)
    if err then c.protocol_error=tostring(err) end; if not data then return end
    local pos=1
    while pos<=#data do
      local ok,message,next_pos=pcall(unpack,data,pos); if not ok then c.protocol_error=tostring(message); return end; pos=next_pos
      if message and message[1]==1 then c.responses[message[2]]=message
      elseif message and message[1]==0 then c.stdin:write(vim.mpack.encode({1,message[2],{0,'Unsupported UI test request'},vim.NIL})) end
    end
  end)
  c.stderr:read_start(function(err,data) if err then c.errors[#c.errors+1]=tostring(err) end; if data then c.errors[#c.errors+1]=data end end)
  function c:request(method,args)
    self.serial=self.serial+1; local id=self.serial
    assert(not self.exited,'Embedded Neovim exited: '..table.concat(self.errors))
    self.stdin:write(vim.mpack.encode({0,id,method,args or {}}))
    local completed=vim.wait(20000,function() return self.responses[id] or self.exited or self.protocol_error end,15)
    if not completed then
      self.serial=self.serial+1; local probe=self.serial
      self.stdin:write(vim.mpack.encode({0,probe,'nvim_get_mode',{}}))
      vim.wait(1000,function() return self.responses[probe]~=nil end,10)
      local diagnostic=self.responses[probe] and self.responses[probe][4] or 'unavailable'
      -- A native hit-enter/file warning must not strand an owned child if an
      -- assertion fails. Escape is fast and leaves modified fixture text intact.
      self.stdin:write(vim.mpack.encode({2,'nvim_input',{'<Esc>'}}))
      pause(60)
      error('Embedded RPC timed out: '..method..'; child '..self.pid..'; mode '..vim.inspect(diagnostic))
    end
    assert(not self.protocol_error,self.protocol_error)
    local response=self.responses[id]; self.responses[id]=nil
    assert(response,'Embedded Neovim exited during '..method..': '..table.concat(self.errors))
    assert(response[3]==nil or response[3]==vim.NIL,'Embedded API failure: '..vim.inspect(response[3]))
    return response[4]
  end
  function c:lua(code,args) return self:request('nvim_exec_lua',{code,args or {}}) end
  function c:input(keys) return self:request('nvim_input',{keys}) end
  function c:status(buf)
    return self:lua("return require('config.autosave').status(...)",buf and {buf} or {})
  end
  function c:view()
    return self:lua([[
      local a=vim.api; local wins={}; local names={'number','relativenumber','signcolumn','cursorline','winfixheight'}
      for _,w in ipairs(a.nvim_tabpage_list_wins(0)) do local b=a.nvim_win_get_buf(w); local opts={}
        for _,name in ipairs(names) do opts[name]=a.nvim_get_option_value(name,{win=w}) end
        wins[tostring(w)]={buf=b,cursor=a.nvim_win_get_cursor(w),view=a.nvim_win_call(w,vim.fn.winsaveview),options=opts,
          width=a.nvim_win_get_width(w),height=a.nvim_win_get_height(w),position=a.nvim_win_get_position(w)}
      end
      local t=require('config.terminal').status()
      return {buf=a.nvim_get_current_buf(),win=a.nvim_get_current_win(),mode=a.nvim_get_mode().mode,
        lines=a.nvim_buf_get_lines(0,0,-1,true),modified=vim.bo.modified,layout=vim.fn.winlayout(),wins=wins,
        terminal=t,channel=t.session and a.nvim_get_chan_info(t.session.job) or vim.NIL,notices=vim.g.autosave_test_notices or {}}
    ]])
  end
  function c:open(name,initial,new)
    local path=self.root..'/'..name
    if not new then fn.mkdir(vim.fs.dirname(path),'p'); fn.writefile(initial or {'initial disk'},path) end
    local buf=self:lua([[
      local path=...; vim.cmd.stopinsert(); vim.o.hidden=true; vim.cmd('edit! '..vim.fn.fnameescape(path)); vim.b.completion=false; return vim.api.nvim_get_current_buf()
    ]],{path})
    return path,buf
  end
  function c:normal()
    if self:view().mode:sub(1,1)=='i' or self:view().mode:sub(1,1)=='R' then self:input('<Esc>') end
    wait_for(function() return self:view().mode:sub(1,1)=='n' end,'Fixture did not return to normal mode')
  end
  function c:change(lines,buf)
    self:lua('local lines,buf=...; vim.api.nvim_buf_set_lines(buf or 0,0,-1,false,lines)',{lines,buf or 0})
  end
  function c:quit()
    if not self.exited then
      pcall(self.stdin.write,self.stdin,vim.mpack.encode({2,'nvim_command',{'qa!'}}))
      wait_for(function() return self.exited~=nil end,'Forced quit did not stop the child',5000)
    end
  end
  function c:shutdown()
    if not self.exited then
      -- Never force a write while cleaning up a failed test.
      pcall(self.lua,self,[[local a=require('config.autosave'); if a.status().enabled then a.toggle() end; local t=require('config.terminal'); for _,s in ipairs(t.sessions()) do t.close(s.id) end]])
      pcall(self.quit,self)
    end
    if not self.exited then pcall(self.handle.kill,self.handle,15); vim.wait(3000,function() return self.exited~=nil end,10) end
    close(self.stdin);close(self.stdout);close(self.stderr);close(self.handle)
  end
  c:request('nvim_ui_attach',{140,46,{ext_linegrid=true,rgb=true}})
  wait_for(function() return c:lua('return vim.g.my_nvim_ready==true') end,'Embedded configuration did not initialize')
  c:lua([[
    vim.g.autosave_test_hooks={}; vim.g.autosave_test_saves={}
    local group=vim.api.nvim_create_augroup('autosave-test-hooks',{clear=true})
    for _,event in ipairs({'BufWritePre','BufWritePost'}) do vim.api.nvim_create_autocmd(event,{group=group,callback=function(args)
      local all=vim.g.autosave_test_hooks; local k=tostring(args.buf); all[k]=all[k] or {pre=0,post=0}
      local field=event=='BufWritePre' and 'pre' or 'post'; all[k][field]=all[k][field]+1; vim.g.autosave_test_hooks=all
    end}) end
    vim.api.nvim_create_autocmd('LspNotify',{group=group,callback=function(args)
      if args.data.method=='textDocument/didSave' then local t=vim.g.autosave_test_saves; t[#t+1]={client_id=args.data.client_id,uri=args.data.params.textDocument.uri}; vim.g.autosave_test_saves=t end
    end})
  ]])
  return c
end
local function saved(c,path,expected,buf)
  wait_for(function() return same_disk(path,expected) end,'Autosave did not write expected disk content: '..path,5000)
  assert(not c:lua('return vim.bo[...].modified',{buf or c:view().buf}),'Successful autosave left the buffer modified')
end
local function paused(c,buf)
  wait_for(function() return c:status(buf).buffer.paused end,'Disk/write conflict did not pause the buffer')
  local state=c:status(buf)
  assert(not state.buffer.pending and type(state.buffer.reason)=='string' and state.buffer.reason~='','Paused buffer did not report a settled reason')
end
local function quit_window(c)
  local path,qbuf=c:open('quit-window-a.txt',{'quit window original'})
  c:lua([[local source=vim.api.nvim_get_current_win(); vim.cmd('vsplit'); vim.cmd('enew!'); vim.api.nvim_set_current_win(source)]])
  c:change({'quit window unsaved'})
  wait_for(function() return c:status(qbuf).buffer.pending end,'Window quit fixture not pending')
  c:lua([[vim.cmd('q!')]])
  pause(1300)
  local state=c:lua([[local b=...; return {valid=vim.api.nvim_buf_is_valid(b),loaded=vim.api.nvim_buf_is_loaded(b),modified=vim.api.nvim_buf_is_valid(b) and vim.bo[b].modified or false,wins=#vim.api.nvim_tabpage_list_wins(0)}]],{qbuf})
  assert(same_disk(path,{'quit window original'}) and state.wins==1,'Forced window quit autosaved abandoned changes: '..vim.inspect(state))
  print('PASS autosave q!: another window survives; discarded buffer never writes after its old timer deadline')
end
local function run()
  local c=spawn()
  assert(c:status().enabled and c:status().delay_ms==1000,'Autosave default is not enabled with a one-second delay')

  if vim.env.MY_NVIM_AUTOSAVE_TEST_CASE=='quit-window' then quit_window(c); return end
  if vim.env.MY_NVIM_AUTOSAVE_TEST_CASE~='completion' then
  local file,buf=c:open('normal.txt',{'initial disk'})
  c:input('iFIRST_'); wait_for(function() return c:view().mode=='i' end,'Insert fixture did not enter i mode')
  pause(1200); assert(same_disk(file,{'initial disk'}),'Autosave wrote while insert mode was active')
  c:input('<Esc>'); c:normal(); wait_for(function() return c:status(buf).buffer.pending end,'InsertLeave did not arm autosave')
  pause(350); c:change({'normal second edit'})
  pause(700); assert(same_disk(file,{'initial disk'}),'Normal TextChanged did not reset the one-second debounce')
  saved(c,file,{'normal second edit'},buf)
  local hooks=c:lua('return vim.g.autosave_test_hooks[tostring(...)]',{buf})
  assert(hooks.pre==1 and hooks.post==1,'Autosave did not run one ordinary BufWritePre/BufWritePost pair')
  print('PASS autosave timing: default one second, no insert writes, InsertLeave scheduling, normal-mode debounce, ordinary write hooks')
  if vim.env.MY_NVIM_AUTOSAVE_TEST_CASE=='basic' then return end

  local reenter,rebuf=c:open('reenter.txt',{'original reenter'})
  c:input('iX'); wait_for(function() return c:view().mode=='i' end,'Reenter fixture not inserting')
  c:input('<Esc>'); c:normal(); wait_for(function() return c:status(rebuf).buffer.pending end,'Reenter fixture not pending')
  pause(350); c:input('i'); wait_for(function() return c:view().mode=='i' end,'Could not reenter the same buffer')
  pause(1100); assert(same_disk(reenter,{'original reenter'}),'Reentering insert mode did not cancel the pending save')
  c:input('Y'); pause(1100); assert(same_disk(reenter,{'original reenter'}),'Continued insertion saved prematurely')
  local desired=c:view().lines; c:input('<Esc>'); c:normal(); saved(c,reenter,desired,rebuf)
  local replace,replacebuf=c:open('replace.txt',{'abcdef'})
  c:input('RXY'); wait_for(function() return c:view().mode:sub(1,1)=='R' end,'Replace fixture did not enter R mode')
  pause(1200); assert(same_disk(replace,{'abcdef'}),'Autosave wrote during replace mode')
  desired=c:view().lines; c:input('<Esc>'); c:normal(); saved(c,replace,desired,replacebuf)
  print('PASS autosave edit modes: same-buffer reentry cancels old timers, replace mode waits until leaving')

  local a,abuf=c:open('background-a.txt',{'A old'})
  local b= c.root..'/background-b.txt'; fn.writefile({'B old'},b)
  c:change({'A background'})
  wait_for(function() return c:status(abuf).buffer.pending end,'Background A did not become pending')
  c:lua('vim.cmd("edit "..vim.fn.fnameescape(...)); vim.b.completion=false',{b})
  local bbuf=c:view().buf; c:change({'B background'})
  local focus=c:view()
  saved(c,a,{'A background'},abuf); saved(c,b,{'B background'},bbuf)
  local after=c:view(); assert(after.win==focus.win and after.buf==focus.buf and vim.deep_equal(after.wins,focus.wins),'Background buffer save changed focus or window views')

  c:lua('vim.api.nvim_set_current_buf(...)',{abuf})
  c:lua([[
    local a,b=...; vim.api.nvim_create_autocmd('BufWritePre',{buffer=a,once=true,callback=function()
      vim.api.nvim_buf_set_lines(b,0,-1,false,{'B changed by another file save hook'})
    end})
  ]],{abuf,bbuf})
  c:change({'A write hook changes hidden B'},abuf)
  saved(c,a,{'A write hook changes hidden B'},abuf)
  saved(c,b,{'B changed by another file save hook'},bbuf)

  c:lua('vim.api.nvim_set_current_buf(...)',{bbuf})
  c:change({'A while another buffer is inserting'},abuf)
  c:input('iACTIVE_'); wait_for(function() return c:view().mode=='i' end,'Other-buffer insertion did not start')
  local inserting=c:view()
  saved(c,a,{'A while another buffer is inserting'},abuf)
  local inserting_after=c:view()
  assert(inserting_after.mode=='i' and inserting_after.buf==bbuf and vim.deep_equal(inserting_after.wins,inserting.wins),'A background save interrupted insertion in a different buffer')
  assert(same_disk(b,{'B changed by another file save hook'}),'Saving a background buffer also saved the actively edited buffer')
  desired=inserting_after.lines; c:input('<Esc>'); c:normal(); saved(c,b,desired,bbuf)

  c:lua('vim.api.nvim_set_current_buf(...)',{abuf}); c:change({'A while terminal visible'})
  c:input('<C-j>'); wait_for(function() return c:view().mode=='t' and c:view().terminal.visible end,'Could not display a real current-window terminal')
  local terminal_before=c:view(); local job=terminal_before.terminal.session.job
  saved(c,a,{'A while terminal visible'},abuf)
  local terminal_after=c:view()
  assert(terminal_after.win==terminal_before.win and terminal_after.buf==terminal_before.buf and terminal_after.mode=='t'
    and vim.deep_equal(terminal_after.layout,terminal_before.layout) and vim.deep_equal(terminal_after.wins,terminal_before.wins),'Saving code behind the terminal changed its window/mode/view')
  assert(terminal_after.terminal.session.job==job and terminal_after.terminal.session.status=='running' and terminal_after.channel.exitcode==-1,'Background autosave restarted/stopped the terminal job')
  assert(not c:status(terminal_after.buf).buffer.pending,'Terminal buffer was considered a disk file')
  c:input('<C-j>'); c:normal()
  print('PASS autosave background: independent buffers and hidden code save without changing focus/views or the real terminal task')

  for _,kind in ipairs({'readonly','nonmodifiable','nofile','uri','untitled'}) do
    local path,g=c:open('guard-'..kind..'.txt',{'guard original'})
    c:lua([[
      local kind=...; if kind=='uri' then vim.api.nvim_buf_set_name(0,'autosave://guard') elseif kind=='untitled' then vim.cmd('enew!') end
      vim.api.nvim_buf_set_lines(0,0,-1,false,{'guard changed'}); vim.b.completion=false
      if kind=='readonly' then vim.bo.readonly=true elseif kind=='nonmodifiable' then vim.bo.modifiable=false elseif kind=='nofile' then vim.bo.buftype='nofile' end
    ]],{kind})
    g=c:view().buf; pause(1200)
    assert(same_disk(path,{'guard original'}),'An ineligible '..kind..' buffer was saved')
    assert((kind=='nofile' or c:lua('return vim.bo[...].modified',{g})) and not c:status(g).buffer.pending and vim.deep_equal(c:view().lines,{'guard changed'}),'Ineligible '..kind..' buffer was marked saved or kept retrying: '..vim.inspect({modified=c:lua('return vim.bo[...].modified',{g}),status=c:status(g)}))
  end
  local fresh,freshbuf=c:open('新 文件 &;$.txt',nil,true)
  c:change({'created by autosave'}); saved(c,fresh,{'created by autosave'},freshbuf)
  local missing,missingbuf=c:open('never-created-parent/file.txt',nil,true)
  c:change({'do not mkdir'}); pause(1300)
  assert(fn.isdirectory(vim.fs.dirname(missing))==0 and fn.filereadable(missing)==0 and c:lua('return vim.bo[...].modified',{missingbuf}),'Autosave created a missing parent directory or discarded its buffer')
  print('PASS autosave guards: readonly/nonmodifiable/special/URI/untitled skipped, named new files created only under existing parents')

  for _,kind in ipairs({'changed','replaced','deleted'}) do
    local path,conflictbuf=c:open('conflict-'..kind..'.txt',{'BASE_0000'})
    c:change({'local unsaved change'})
    wait_for(function() return c:status(conflictbuf).buffer.pending end,'Conflict fixture did not queue a save')
    local external; if kind~='deleted' then external={'DISK_9999'} end
    if kind=='changed' then fn.writefile(external,path)
    elseif kind=='replaced' then
      local replacement=path..'.replacement'; fn.writefile(external,replacement)
      assert(uv.fs_rename(path,path..'.old')); assert(uv.fs_rename(replacement,path))
    else assert(uv.fs_unlink(path)) end
    paused(c,conflictbuf)
    assert(vim.deep_equal(disk(path),external),'Autosave overwrote an externally '..kind..' file')
    assert(c:lua('return vim.bo[...].modified',{conflictbuf}),'Conflict discarded modified buffer contents')
    if kind=='changed' then
      c:lua('vim.cmd("edit!")'); assert(not c:status(conflictbuf).buffer.paused,'Successful read did not reset the conflict baseline')
      c:change({'saved after manual read'}); saved(c,path,{'saved after manual read'},conflictbuf)
    else
      c:lua('vim.cmd("write!")'); assert(not c:status(conflictbuf).buffer.paused,'Successful manual write did not reset the conflict baseline')
      c:change({'saved after manual write'}); saved(c,path,{'saved after manual write'},conflictbuf)
    end
  end
  print('PASS autosave conflicts: changed/replaced/deleted files pause without overwrite; successful manual read/write reestablishes baseline')

  local failure,failbuf=c:open('write-failure.txt',{'write original'})
  local hook=c:lua([[return vim.api.nvim_create_autocmd('BufWritePre',{buffer=0,callback=function() error('AUTOSAVE_TEST_WRITE_FAILURE') end})]])
  local notices_before=#c:view().notices
  c:change({'write must fail'}); paused(c,failbuf)
  assert(same_disk(failure,{'write original'}) and c:lua('return vim.bo[...].modified',{failbuf}),'A failed write lost disk/buffer state')
  local attempts=c:lua('return vim.g.autosave_test_hooks[tostring(...)].pre',{failbuf})
  for index=1,3 do c:change({'paused edit '..index}); pause(100) end
  pause(1200)
  assert(c:lua('return vim.g.autosave_test_hooks[tostring(...)].pre',{failbuf})==attempts,'A paused failure retried automatically')
  assert(#c:view().notices-notices_before<=1,'A write failure repeatedly notified the user')
  c:lua('vim.api.nvim_del_autocmd(...); vim.cmd("write")',{hook})
  assert(not c:status(failbuf).buffer.paused,'Successful manual write did not clear write-failure pause')
  c:change({'write recovered'}); saved(c,failure,{'write recovered'},failbuf)
  print('PASS autosave failures: ordinary write-hook failure keeps modified state, pauses without retries/spam, manual write resumes')

  end
  local function completion_text() return c:request('nvim_buf_get_lines',{0,0,-1,true}) end
  local function completion_mode() return c:request('nvim_get_mode',{}).mode end
  local completion_lines={'ordinaryAlpha ordinaryBeta','ord TAIL'}
  local completion,completionbuf=c:open('blink-menu.txt',completion_lines)
  c:lua([[vim.b.completion=true; require('blink.cmp.config').completion.list.selection.auto_insert=true; vim.api.nvim_win_set_cursor(0,{2,3})]])
  c:input('i'); wait_for(function() return completion_mode()=='i' end,'Completion fixture did not enter insert mode')
  local function show_completion()
    c:lua([[require('blink.cmp').show({providers={'buffer'}})]])
    wait_for(function() return c:lua([[return require('blink.cmp').is_menu_visible()]]) end,'Real Blink completion menu did not appear')
    c:input('<C-n>')
    wait_for(function() return completion_text()[2]:find('ordinary',1,true)~=nil end,'Real Blink completion preview did not appear')
  end
  show_completion(); pause(1200)
  assert(same_disk(completion,completion_lines),'Autosave persisted an active completion preview')
  c:input('<C-e>'); wait_for(function() return not c:lua([[return require('blink.cmp').is_menu_visible()]]) end,'Ctrl-e did not hide the real Blink menu')
  assert(vim.deep_equal(completion_text(),completion_lines),'Cancel did not undo the real Blink preview: '..vim.inspect(completion_text()))
  c:input('<Esc>'); c:normal(); pause(1200)
  assert(same_disk(completion,completion_lines),'Cancel followed by Escape saved an unaccepted preview')
  c:lua([[vim.api.nvim_win_set_cursor(0,{2,3})]])
  c:input('i'); wait_for(function() return completion_mode()=='i' end,'Completion accept fixture did not enter insert mode')
  show_completion(); c:input('<C-y>')
  wait_for(function() return not c:lua([[return require('blink.cmp').is_menu_visible()]]) end,'Ctrl-y did not accept the real Blink candidate')
  local accepted=completion_text()
  assert(accepted[2]:find('ordinary',1,true),'Accepted Blink candidate was not inserted into the actual buffer')
  pause(1100); assert(same_disk(completion,completion_lines),'Accepted completion saved before leaving insert mode')
  c:input('<Esc>'); c:normal(); pause(350)
  assert(same_disk(completion,completion_lines),'Accepted completion bypassed the normal one-second debounce')
  saved(c,completion,accepted,completionbuf)
  print('PASS autosave completion: real Blink preview remains unwritten; cancel restores original text, acceptance saves only after InsertLeave')

  local cpp,cppbuf=c:open('did-save.cpp',{'int    value(  ) {  return  1; }'})
  if c:lua("return vim.lsp.is_enabled('clangd')") then
    wait_for(function() return c:lua("return #vim.lsp.get_clients({bufnr=...,name='clangd'})>0",{cppbuf}) end,'clangd did not attach for didSave verification',30000)
    c:change({'int    value(  ) {  return  2; }'}); saved(c,cpp,{'int    value(  ) {  return  2; }'},cppbuf)
    wait_for(function() return c:lua([[local uri=vim.uri_from_bufnr(...); for _,event in ipairs(vim.g.autosave_test_saves) do if event.uri==uri then return true end end; return false]],{cppbuf}) end,'Normal autosave did not emit LSP textDocument/didSave')
    assert(same_disk(cpp,{'int    value(  ) {  return  2; }'}),'Autosave introduced automatic formatting')
    c:lua([[vim.lsp.buf.format({bufnr=...,async=false,timeout_ms=5000})]],{cppbuf})
    local formatted=c:view().lines
    assert(not vim.deep_equal(formatted,{'int    value(  ) {  return  2; }'}),'Real clangd manual format did not change the fixture')
    wait_for(function() return c:status(cppbuf).buffer.pending end,'Manual format did not schedule autosave')
    pause(350); assert(same_disk(cpp,{'int    value(  ) {  return  2; }'}),'Manual formatting skipped the one-second debounce')
    saved(c,cpp,formatted,cppbuf)
    print('PASS autosave LSP: real clangd didSave, no automatic formatting, manual LSP format schedules a delayed normal write')
  else print('SKIP autosave real didSave: clangd unavailable; ordinary write hooks were verified') end

  local toggled,tbuf=c:open('toggle.txt',{'toggle original'})
  c:change({'must not save while disabled'}); wait_for(function() return c:status(tbuf).buffer.pending end,'Toggle fixture not pending')
  assert(c:lua("return require('config.autosave').toggle()")==false,'Toggle did not disable autosave')
  pause(1200); assert(same_disk(toggled,{'toggle original'}) and c:status().pending_count==0,'Disabling did not cancel pending writes')
  assert(c:lua("return require('config.autosave').toggle()")==true,'Toggle did not reenable autosave')
  c:change({'saved after reenable'}); saved(c,toggled,{'saved after reenable'},tbuf)
  quit_window(c)
  c:shutdown()
  local disabled=spawn(false); local disabled_file,dbuf=disabled:open('disabled.txt',{'disabled original'})
  disabled:change({'disabled edit'}); pause(1200)
  assert(not disabled:status().enabled and same_disk(disabled_file,{'disabled original'}),'enabled=false still wrote a file')
  disabled:shutdown()

  local exit=spawn(true); local exitfile,exitbuf=exit:open('force-quit.txt',{'forcequit original'})
  exit:change({'forcequit unsaved'}); wait_for(function() return exit:status(exitbuf).buffer.pending end,'Force-quit fixture not pending')
  exit:quit(); pause(1100)
  assert(same_disk(exitfile,{'forcequit original'}),'Forced quit flushed a pending autosave')
  assert(exit.exited.code==0,'Forced-quit fixture did not exit cleanly')
  print('PASS autosave controls: disabled configuration/toggle cancel timers, forced quit never flushes pending edits')
end
vim.schedule(function()
  local ok,err=xpcall(run,debug.traceback)
  for _,c in ipairs(children) do pcall(c.shutdown,c) end
  if not ok then api.nvim_err_writeln(err); vim.cmd('cquit 1') else print('PASS all autosave integration scenarios'); vim.cmd('qa!') end
end)
