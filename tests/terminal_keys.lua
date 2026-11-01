-- nvim --headless -u ./init.lua -c "lua dofile('tests/terminal_keys.lua')"
-- Real embedded UI and keyboard dispatch, with a real non-stdin-dependent PTY.
assert(vim.g.my_nvim_ready,'Load the my-nvim configuration before this test')
local api,fn,uv=vim.api,vim.fn,vim.uv
local config_root=assert(vim.g.my_nvim_root)
local base=vim.fs.joinpath(fn.stdpath('cache'),'my-nvim-terminal-key-tests',tostring(uv.os_getpid()))
fn.mkdir(base,'p')
local child
local function close(h) if h and not h:is_closing() then h:close() end end
local function wait_for(predicate,message,timeout) assert(vim.wait(timeout or 10000,predicate,15),message) end
local function env_list(env) local result={}; for k,v in pairs(env) do result[#result+1]=k..'='..v end; return result end
local function spawn()
  local command=fn.has('win32')==1 and {'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-Command','[Threading.Thread]::Sleep(120000)'} or {'/bin/sleep','120'}
  local early=('lua vim.g.my_nvim_root=%q; vim.opt.rtp:prepend(%q); local m=require("config.machine").load(); m.project=vim.tbl_extend("force",m.project or {},{state_dir=%q}); m.deepseek={enabled=false}; m.terminal={shell=vim.json.decode(%q)}')
    :format(config_root,config_root,vim.fs.joinpath(base,'state'),vim.json.encode(command))
  local environment=require('config.project_native').child_env()
  for key in pairs(environment) do if key:upper()=='DEEPSEEK_API_KEY' then environment[key]=nil end end
  local c={stdin=uv.new_pipe(false),stdout=uv.new_pipe(false),stderr=uv.new_pipe(false),responses={},serial=0,errors={}}
  child=c
  c.handle=assert(uv.spawn(vim.v.progpath,{args={'--embed','-i','NONE','--cmd',early,'-u',vim.fs.joinpath(config_root,'init.lua')},
    cwd=base,env=env_list(environment),hide=true,stdio={c.stdin,c.stdout,c.stderr}},function(code,signal) c.exited={code=code,signal=signal}; close(c.handle) end))
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
    wait_for(function() return self.responses[id] or self.exited or self.protocol_error end,'Embedded RPC timeout: '..method,20000)
    assert(not self.protocol_error,self.protocol_error)
    local response=self.responses[id]; self.responses[id]=nil
    assert(response,'Embedded Neovim exited during '..method..': '..table.concat(self.errors))
    assert(response[3]==nil or response[3]==vim.NIL,'Embedded API failure: '..vim.inspect(response[3]))
    return response[4]
  end
  function c:lua(code,args) return self:request('nvim_exec_lua',{code,args or {}}) end
  function c:input(keys) return self:request('nvim_input',{keys}) end
  function c:snapshot()
    return self:lua([[
      local api=vim.api; local options={'number','relativenumber','signcolumn','cursorline','winfixheight'}; local wins={}
      for _,win in ipairs(api.nvim_tabpage_list_wins(0)) do
        local buf=api.nvim_win_get_buf(win); local opts={}
        for _,name in ipairs(options) do opts[name]=api.nvim_get_option_value(name,{win=win}) end
        wins[tostring(win)]={buf=buf,view=api.nvim_win_call(win,vim.fn.winsaveview),options=opts,cursor=api.nvim_win_get_cursor(win),
          width=api.nvim_win_get_width(win),height=api.nvim_win_get_height(win),position=api.nvim_win_get_position(win),
          modified=vim.bo[buf].modified,first=api.nvim_buf_get_lines(buf,0,1,true)[1] or ''}
      end
      local state=require('config.terminal').status()
      return {win=api.nvim_get_current_win(),buf=api.nvim_get_current_buf(),mode=api.nvim_get_mode().mode,
        layout=vim.fn.winlayout(),wins=wins,state=state,sessions=require('config.terminal').sessions(),
        channel=state.session and vim.api.nvim_get_chan_info(state.session.job) or vim.NIL}
    ]])
  end
  function c:shutdown()
    if not self.exited then
      pcall(self.lua,self,[[local root=...; local t=require('config.terminal'); local jobs={}; for _,s in ipairs(t.sessions(root)) do jobs[#jobs+1]=s.job; t.close(s.id) end; if #jobs>0 then vim.fn.jobwait(jobs,5000) end]],{base})
      pcall(self.stdin.write,self.stdin,vim.mpack.encode({2,'nvim_command',{'qa!'}})); vim.wait(5000,function() return self.exited~=nil end,10)
    end
    if not self.exited then pcall(self.handle.kill,self.handle,15); vim.wait(3000,function() return self.exited~=nil end,10) end
    close(self.stdin);close(self.stdout);close(self.stderr);close(self.handle)
  end
  c:request('nvim_ui_attach',{140,46,{ext_linegrid=true,rgb=true}})
  wait_for(function() return c:lua('return vim.g.my_nvim_ready==true') end,'Embedded configuration did not become ready')
  return c
end
local function invariant(before,after,target)
  local target_key=tostring(target)
  assert(vim.deep_equal(before.layout,after.layout),'Keyboard toggle created/closed/reordered windows')
  assert(vim.tbl_count(before.wins)==vim.tbl_count(after.wins),'Keyboard toggle changed the window count')
  for win,previous in pairs(before.wins) do
    local actual=assert(after.wins[win],'Keyboard toggle deleted another window')
    assert(actual.width==previous.width and actual.height==previous.height and vim.deep_equal(actual.position,previous.position),'Keyboard toggle resized a window')
    if win~=target_key then assert(vim.deep_equal(actual,previous),'Keyboard toggle changed another window buffer/view/options/content') end
  end
  assert(after.win==target,'Keyboard toggle moved focus out of the current window')
end
local function restored(before,after,win,label)
  invariant(before,after,win)
  local expected,actual=before.wins[tostring(win)],after.wins[tostring(win)]
  assert(actual.buf==expected.buf,label..': wrong source buffer')
  assert(vim.deep_equal(actual.cursor,expected.cursor),label..': cursor changed: '..vim.inspect({expected=expected.cursor,actual=actual.cursor}))
  local actual_view,expected_view=vim.deepcopy(actual.view),vim.deepcopy(expected.view)
  -- Insert-mode desired-column cache is refreshed by the next arrow motion;
  -- compare actual motion against a baseline below, while keeping visible view strict.
  if before.mode:sub(1,1)=='i' and after.mode:sub(1,1)=='i' then actual_view.curswant=nil; expected_view.curswant=nil end
  assert(vim.deep_equal(actual_view,expected_view),label..': scroll/cursor view changed: '..vim.inspect({expected=expected_view,actual=actual_view}))
  assert(vim.deep_equal(actual.options,expected.options) and actual.modified==expected.modified and actual.first==expected.first,label..': editor state changed')
end
local function run()
  local result=vim.system({'git','init','--quiet',base},{text=true}):wait(10000); assert(result.code==0,'Cannot create disposable Git project')
  local one,two=vim.fs.joinpath(base,'one.txt'),vim.fs.joinpath(base,'two.txt')
  local lines={'end_of_line'}; for index=2,180 do lines[index]=('line %03d '):format(index)..string.rep('x',180) end
  fn.writefile(lines,one); fn.writefile(lines,two)
  local c=spawn()
  local ids=c:lua([[
    local one,two=...; vim.cmd('edit '..vim.fn.fnameescape(one)); local a=vim.api.nvim_get_current_win()
    vim.b.completion=false
    vim.api.nvim_buf_set_lines(0,0,1,false,{'end_of_line'})
    vim.bo.modified=true
    vim.cmd('vsplit '..vim.fn.fnameescape(two)); local b=vim.api.nvim_get_current_win(); vim.b.completion=false
    local function configure(win,lnum,col,top,left,opts)
      vim.api.nvim_set_current_win(win); vim.wo.wrap=false
      for k,v in pairs(opts) do vim.api.nvim_set_option_value(k,v,{win=win}) end
      vim.api.nvim_win_set_cursor(win,{lnum,col}); vim.fn.winrestview({lnum=lnum,col=col,topline=top,leftcol=left,curswant=col})
    end
    configure(b,80,30,70,10,{number=false,relativenumber=false,signcolumn='auto:1-3',cursorline=false,winfixheight=true})
    configure(a,1,10,1,0,{number=true,relativenumber=true,signcolumn='yes:2',cursorline=true,winfixheight=false})
    for _,name in ipairs({'TerminalToggle','TerminalNew','TerminalSelect','TerminalClose'}) do assert(vim.fn.exists(':'..name)==2,name..' missing') end
    return {a,b}
  ]],{one,two})
  local win1,win2=ids[1],ids[2]
  local function terminal_in(win)
    local entered=vim.wait(3000,function() local s=c:snapshot(); return s.win==win and s.state.visible and s.state.win==win and s.mode=='t' end,15)
    assert(entered,'Current-window terminal did not enter input mode: '..vim.inspect(c:snapshot()))
    local s=c:snapshot(); assert(s.state.session.status=='running' and s.channel.exitcode==-1,'Terminal fixture process is not alive'); return s
  end
  local function editor_in(win,mode,buf)
    wait_for(function() local s=c:snapshot(); return s.win==win and s.buf==buf and not s.state.visible and s.mode:sub(1,1)==mode end,'Ctrl-j did not return to source mode '..mode)
    return c:snapshot()
  end

  -- Enter from the exact end of a line: C-\\ C-n must not silently move it left.
  c:input('A'); wait_for(function() return c:snapshot().mode=='i' end,'Could not enter insert mode at EOL')
  local eol=c:snapshot(); assert(eol.wins[tostring(win1)].cursor[2]==#'end_of_line','EOL fixture cursor is not after the last character')
  c:input('<C-j>'); local shown=terminal_in(win1); invariant(eol,shown,win1)
  local job=shown.state.session.job
  c:input('<C-j>'); local eol_return=editor_in(win1,'i',eol.buf)
  local eol_ready=vim.wait(1000,function() return vim.deep_equal(c:snapshot().wins[tostring(win1)].cursor,eol.wins[tostring(win1)].cursor) end,15)
  assert(eol_ready,'Insert EOL cursor did not restore after mode settled: '..vim.inspect({expected=eol.wins[tostring(win1)].cursor,actual=c:snapshot().wins[tostring(win1)].cursor}))
  restored(eol,c:snapshot(),win1,'Insert EOL return')
  c:input('<Esc>'); wait_for(function() return c:snapshot().mode=='n' end,'Escape did not leave source insert mode')

  c:lua([[local win=...; vim.api.nvim_set_current_win(win); vim.api.nvim_win_set_cursor(win,{120,70}); vim.fn.winrestview({lnum=120,col=70,curswant=70,topline=109,leftcol=35})]],{win1})
  local normal=c:snapshot()
  c:input('<C-j>'); shown=terminal_in(win1); invariant(normal,shown,win1); assert(shown.state.session.job==job,'Normal-mode toggle restarted the shell')
  c:input('<C-j>'); restored(normal,editor_in(win1,'n',normal.buf),win1,'Normal return')

  -- Share one job in two windows but return each to its own source and mode.
  c:input('<C-j>'); terminal_in(win1)
  c:input(string.char(28)..string.char(14))
  wait_for(function() return c:snapshot().mode:sub(1,1)=='n' end,'Could not enter terminal-normal mode')
  c:lua('vim.api.nvim_set_current_win(...)',{win2}); c:input('i')
  wait_for(function() return c:snapshot().mode=='i' end,'Could not enter second source insert mode')
  local second=c:snapshot()
  c:input('<Down>'); wait_for(function() return c:snapshot().wins[tostring(win2)].cursor[1]==81 end,'Insert baseline Down did not move a row')
  local baseline_down=c:snapshot().wins[tostring(win2)].cursor
  c:input('<Up>'); wait_for(function() return c:snapshot().wins[tostring(win2)].cursor[1]==80 end,'Insert baseline Up did not return a row')
  assert(vim.deep_equal(c:snapshot().wins[tostring(win2)].cursor,second.wins[tostring(win2)].cursor),'Insert baseline changed its column')
  second=c:snapshot()
  c:input('<C-j>'); local twice=terminal_in(win2); invariant(second,twice,win2)
  assert(twice.state.session.job==job and twice.wins[tostring(win1)].buf==twice.buf,'Two windows did not share the same live terminal')
  c:input('<C-j>'); restored(second,editor_in(win2,'i',second.buf),win2,'Independent second insert return')
  c:input('<Down>'); wait_for(function() return c:snapshot().wins[tostring(win2)].cursor[1]==81 end,'Returned insert Down did not move a row')
  assert(vim.deep_equal(c:snapshot().wins[tostring(win2)].cursor,baseline_down),'Returned insert Down changed the desired column versus baseline: '..vim.inspect({expected=baseline_down,actual=c:snapshot().wins[tostring(win2)].cursor}))
  c:input('<Up>'); wait_for(function() return c:snapshot().wins[tostring(win2)].cursor[1]==80 end,'Returned insert Up did not return a row')
  assert(vim.deep_equal(c:snapshot().wins[tostring(win2)].cursor,second.wins[tostring(win2)].cursor),'Returned insert Up changed the original column')
  c:input('<Esc>'); wait_for(function() return c:snapshot().mode=='n' end,'Second source did not leave insert mode')
  c:lua('vim.api.nvim_set_current_win(...)',{win1})
  local terminal_normal=c:snapshot(); c:input('<C-j>'); local back=editor_in(win1,'n',normal.buf)
  assert(vim.deep_equal(back.wins[tostring(win1)],normal.wins[tostring(win1)]),'Terminal-normal toggle lost its first window origin')
  invariant(terminal_normal,back,win1)

  print('PASS terminal key cursors: exact EOL and middle positions, actual Up/Down baseline, independent source modes')
  -- Leader new/select/close use the same target window, keeping the first origin.
  local before_new=c:snapshot(); c:input(' tn'); local created=terminal_in(win1)
  invariant(before_new,created,win1); assert(created.state.session.job~=job and #created.sessions==2,'Leader tn did not create another same-project session')
  c:input(string.char(28)..string.char(14)); wait_for(function() return c:snapshot().mode:sub(1,1)=='n' end,'New terminal did not enter terminal-normal mode')
  c:input(' ts')
  wait_for(function() return c:lua([[for _,w in ipairs(vim.api.nvim_list_wins()) do if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='TelescopePrompt' then return true end end; return false]]) end,'Leader ts did not open the real selector')
  wait_for(function() return c:lua([[return vim.bo.filetype=='TelescopePrompt' and vim.api.nvim_get_mode().mode=='i']]) end,'Terminal selector did not enter real prompt insert mode')
  c:lua([[
    local prompt; for _,w in ipairs(vim.api.nvim_list_wins()) do local b=vim.api.nvim_win_get_buf(w); if vim.bo[b].filetype=='TelescopePrompt' then prompt=b end end
    local p=require('telescope.actions.state').get_current_picker(prompt)
    assert(vim.wait(5000,function() return p.manager and p.manager:num_results()>=2 end,10))
    p:set_selection(p:get_row(2))
  ]])
  c:input('<CR>')
  local picked=terminal_in(win1); invariant(before_new,picked,win1)
  c:input('<C-j>'); restored(before_new,editor_in(win1,'n',before_new.buf),win1,'Leader select kept first origin')
  c:input(' tx'); wait_for(function() return #c:snapshot().sessions==1 end,'Leader tx did not close the selected session')
  restored(before_new,c:snapshot(),win1,'Leader close from code')
  print('PASS terminal keys: real embedded n/i/t Ctrl-j, exact insert/EOL cursor and scroll/options, current-window-only geometry, two independent origins/modes, shared real job, leader tn/ts/tx, original source preservation')
end
vim.schedule(function()
  local ok,err=xpcall(run,debug.traceback)
  if child then pcall(child.shutdown,child) end
  if not ok then api.nvim_err_writeln(err); vim.cmd('cquit 1') else vim.cmd('qa!') end
end)
