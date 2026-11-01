-- nvim --headless -u ./init.lua -c "lua dofile('tests/explorer.lua')"
-- Real embedded keyboard/UI, locked Snacks/FFF and disk operations; cache only.
assert(vim.g.my_nvim_ready,'Load the my-nvim configuration before this test')
local api,fn,uv=vim.api,vim.fn,vim.uv
local config_root=assert(vim.g.my_nvim_root)
local base=vim.fs.joinpath(fn.stdpath('cache'),'my-nvim-explorer-tests',tostring(uv.os_getpid())..'-'..tostring(uv.hrtime()))
local clients={}
fn.mkdir(base,'p')
local function pause(ms) vim.wait(ms,function() return false end,10) end
local function wait_for(predicate,message,timeout)
  local deadline=uv.hrtime()+(timeout or 8000)*1000000
  repeat if predicate() then return end; pause(15) until uv.hrtime()>=deadline
  error(message,2)
end
local function close(h) if h and not h:is_closing() then h:close() end end
local function write(path,lines) fn.mkdir(vim.fs.dirname(path),'p'); assert(fn.writefile(lines,path)==0) end
local function disk(path) return fn.filereadable(path)==1 and fn.readfile(path) or nil end
local function same(a,b)
  if not a or not b then return false end
  local function norm(p) p=vim.fs.normalize(p):gsub('[/\\]+$',''); return fn.has('win32')==1 and p:lower() or p end
  return norm(a)==norm(b)
end
local function file_exists(path) return uv.fs_stat(path)~=nil end
local function spawn(root,restore)
  local index=#clients+1
  local state=base..'/state'; fn.mkdir(state,'p'); fn.mkdir(base..'/undo-'..index,'p')
  local shell=fn.has('win32')==1 and {'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-Command','[Threading.Thread]::Sleep(120000)'} or {'/bin/sleep','120'}
  local early=('lua vim.g.my_nvim_root=%q; vim.opt.rtp:prepend(%q); local m=require("config.machine").load(); m.project=vim.tbl_extend("force",m.project or {},{state_dir=%q}); m.deepseek={enabled=false}; m.autosave={}; m.terminal={shell=vim.json.decode(%q)}; vim.o.swapfile=false; vim.opt.undodir=%q')
    :format(config_root,config_root,state,vim.json.encode(shell),base..'/undo-'..index)
  local env=require('config.project_native').child_env(); local environment={}
  for k,v in pairs(env) do if k:upper()~='DEEPSEEK_API_KEY' then environment[#environment+1]=k..'='..v end end
  local c={root=root,responses={},serial=0,errors={},stdin=uv.new_pipe(false),stdout=uv.new_pipe(false),stderr=uv.new_pipe(false)}
  clients[#clients+1]=c
  c.handle,c.pid=uv.spawn(vim.v.progpath,{args={'--embed','-i','NONE','--cmd',early,'-u',config_root..'/init.lua'},cwd=root,env=environment,hide=true,stdio={c.stdin,c.stdout,c.stderr}},function(code,signal) c.exited={code=code,signal=signal}; close(c.handle) end)
  assert(c.handle,c.pid)
  local unpack=vim.mpack.Unpacker()
  c.stdout:read_start(function(err,data)
    if err then c.protocol_error=tostring(err) end; if not data then return end
    local pos=1
    while pos<=#data do local ok,message,next_pos=pcall(unpack,data,pos)
      if not ok then c.protocol_error=tostring(message); return end; pos=next_pos
      if message and message[1]==1 then c.responses[message[2]]=message
      elseif message and message[1]==0 then c.stdin:write(vim.mpack.encode({1,message[2],{0,'Unsupported UI test request'},vim.NIL})) end
    end
  end)
  c.stderr:read_start(function(err,data) if err then c.errors[#c.errors+1]=tostring(err) end; if data then c.errors[#c.errors+1]=data end end)
  function c:request(method,args)
    self.serial=self.serial+1; local id=self.serial
    assert(not self.exited,'Owned test UI exited: '..table.concat(self.errors))
    self.stdin:write(vim.mpack.encode({0,id,method,args or {}}))
    if not vim.wait(15000,function() return self.responses[id] or self.protocol_error or self.exited end,15) then
      self.serial=self.serial+1; local probe=self.serial; self.stdin:write(vim.mpack.encode({0,probe,'nvim_get_mode',{}}))
      vim.wait(500,function() return self.responses[probe]~=nil end,10)
      self.stdin:write(vim.mpack.encode({2,'nvim_input',{'<Esc>'}})); pause(50)
      error('Embedded UI RPC timeout '..method..' pid '..self.pid..': '..vim.inspect(self.responses[probe]))
    end
    assert(not self.protocol_error,self.protocol_error)
    local r=self.responses[id]; self.responses[id]=nil
    assert(r,'Owned test UI exited during '..method..': '..table.concat(self.errors))
    assert(r[3]==nil or r[3]==vim.NIL,'Embedded API error: '..vim.inspect(r[3]))
    return r[4]
  end
  function c:lua(code,args) return self:request('nvim_exec_lua',{code,args or {}}) end
  function c:input(keys) return self:request('nvim_input',{keys}) end
  function c:mode() return self:request('nvim_get_mode',{}).mode end
  function c:current()
    return self:lua([[return {win=vim.api.nvim_get_current_win(),buf=vim.api.nvim_get_current_buf(),name=vim.api.nvim_buf_get_name(0),mode=vim.api.nvim_get_mode().mode,ft=vim.bo.filetype,modified=vim.bo.modified,cursor=vim.api.nvim_win_get_cursor(0),lines=vim.api.nvim_buf_get_lines(0,0,-1,true)}]])
  end
  function c:windows()
    -- Pure observation: nvim_win_call while a picker is active changes its context.
    return self:lua([[local out={}; for _,w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do local b=vim.api.nvim_win_get_buf(w); out[#out+1]={win=w,buf=b,name=vim.api.nvim_buf_get_name(b),relative=vim.api.nvim_win_get_config(w).relative,width=vim.api.nvim_win_get_width(w),height=vim.api.nvim_win_get_height(w),position=vim.api.nvim_win_get_position(w),cursor=vim.api.nvim_win_get_cursor(w)} end; return out]])
  end
  function c:tree()
    return self:lua([[
      local s=require('config.explorer').status(); local p=s.picker; local out={visible=s.visible,window=s.window or s.win,main_win=s.main_win,root=s.root,items={},current_win=vim.api.nvim_get_current_win(),mode=vim.api.nvim_get_mode().mode}
      if p and not p.closed then
        for item,idx in p:iter() do out.items[#out.items+1]={file=item.file,dir=item.dir==true,open=item.open==true,index=idx} end
        local item=p:current(); out.selected=item and item.file or nil; out.hidden=p.opts.hidden; out.ignored=p.opts.ignored
        out.pattern=p.input and p.input.filter.pattern or nil
      end
      if out.window and vim.api.nvim_win_is_valid(out.window) then out.width=vim.api.nvim_win_get_width(out.window); out.position=vim.api.nvim_win_get_position(out.window) end
      return out
    ]])
  end
  function c:select(path)
    wait_for(function()
      return self:lua([[
        local path=...; local p=require('config.explorer').status().picker; if not p or p.closed then return false end
        local function key(value) value=vim.fs.normalize(value); return vim.fn.has('win32')==1 and value:lower() or value end
        local current=p:current(); if current and key(current.file)==key(path) then p.list.win:focus(); return true end
        for item,idx in p:iter() do if key(item.file)==key(path) then p.list:view(idx); p.list.win:focus(); return false end end
        return false
      ]],{path})
    end,'Tree selection did not reach '..path)
  end
  function c:open(path)
    self:lua([[local path=...; vim.o.hidden=true; vim.cmd('edit '..vim.fn.fnameescape(path)); vim.b.completion=false]],{path})
    return self:current()
  end
  function c:shutdown()
    if not self.exited then
      pcall(self.lua,self,[[local a=require('config.autosave'); if a.status().enabled then a.toggle() end; local e=require('config.explorer'); if e.status().visible then e.toggle() end; local t=require('config.terminal'); for _,s in ipairs(t.sessions()) do t.close(s.id) end]])
      pcall(self.stdin.write,self.stdin,vim.mpack.encode({2,'nvim_command',{'qa!'}}))
      vim.wait(5000,function() return self.exited~=nil end,10)
    end
    if not self.exited then pcall(self.handle.kill,self.handle,15); vim.wait(3000,function() return self.exited~=nil end,10) end
    close(self.stdin); close(self.stdout); close(self.stderr); close(self.handle)
  end
  c:request('nvim_ui_attach',{150,45,{ext_linegrid=true,rgb=true}})
  wait_for(function() return c:lua('return vim.g.my_nvim_ready==true') end,'Configuration did not initialize')
  c:lua([[local root,restore=...; return require('config.project').activate(root,{restore=restore,pick=false})]],{root,restore==true})
  return c
end
local function has(tree,path) for _,i in ipairs(tree.items) do if same(i.file,path) then return true end end; return false end
local function tree_open(c)
  if not c:tree().visible then c:input(' e') elseif c:tree().current_win~=c:tree().window then c:lua([[require('config.explorer').focus()]]) end
  wait_for(function() local s=c:tree(); return s.visible and s.window==s.current_win and #s.items>0 end,'Explorer did not open and focus its real list')
  return c:tree()
end
local function tree_close(c,key)
  if c:tree().visible then c:input(key or 'q') end
  wait_for(function() return not c:tree().visible end,'Explorer did not close')
end
local function fixtures()
  local root=base.."/项目 空格 &';$ git"; fn.mkdir(root,'p')
  assert(vim.system({'git','init','--quiet',root},{text=true}):wait().code==0)
  for path,lines in pairs({['main.txt']={'main code'},['other.txt']={'other code'},['.secret']={'hidden content'},['.gitignore']={'ignored.txt','ignored-dir/'},['ignored.txt']={'ignored content'},['ignored-dir/inside.txt']={'ignored directory child'},['folder/child.txt']={'folder child'},['folder/deep/target.txt']={'nested searchable target'}}) do write(root..'/'..path,lines) end
  local nongit=base..'/非 Git 空间'; write(nongit..'/文件 空格.txt',{'non git file'})
  return root,nongit
end
local function tree_keys(c,root,nongit)
  assert(not c:tree().visible,'Explorer opened automatically at startup')
  local main=c:open(root..'/main.txt'); local initial=tree_open(c)
  assert(initial.width==40 and initial.position[2]==0,'Explorer is not a forty-column left sidebar')
  assert(same(initial.root,root) and initial.main_win==main.win,'Explorer did not retain the active project/editor target')
  wait_for(function() local s=c:tree(); return has(s,root..'/ignored.txt') and has(s,root..'/.secret') end,'Default explorer did not show ignored/dot files')
  assert(not has(c:tree(),root..'/.git'),'Explorer exposed .git internals')
  c:input('I'); wait_for(function() return not has(c:tree(),root..'/ignored.txt') end,'I did not hide ignored files')
  c:input('I'); wait_for(function() return has(c:tree(),root..'/ignored.txt') end,'I did not restore ignored files')
  c:input('H'); wait_for(function() return not has(c:tree(),root..'/.secret') end,'H did not hide dot files')
  c:input('H'); wait_for(function() return has(c:tree(),root..'/.secret') end,'H did not restore dot files')
  assert(not has(c:tree(),root..'/.git'),'I/H made .git visible')
  c:input('gg'); local first=c:tree().selected; c:input('j'); wait_for(function() return not same(c:tree().selected,first) end,'j did not move down the tree')
  c:input('k'); wait_for(function() return same(c:tree().selected,first) end,'k did not move back up the tree')
  c:select(root..'/folder'); c:input('l'); wait_for(function() return has(c:tree(),root..'/folder/child.txt') end,'l did not expand a folder')
  c:input('h'); wait_for(function() return not has(c:tree(),root..'/folder/child.txt') end,'h did not collapse a folder')
  c:select(root..'/folder'); c:input('<CR>'); wait_for(function() return has(c:tree(),root..'/folder/child.txt') end,'Enter did not expand a folder')
  c:select(root..'/folder/child.txt'); c:input('<CR>')
  wait_for(function() return c:current().win==main.win and same(c:current().name,root..'/folder/child.txt') end,'Enter opened a file outside the remembered editor window')
  assert(c:tree().visible,'Opening a file closed the persistent tree')
  c:input(' o'); wait_for(function() return c:current().win==c:tree().window end,'Leader o did not focus the tree')
  c:input(' o'); wait_for(function() return c:current().win==main.win end,'Leader o did not return to the editor')
  c:input(' e'); wait_for(function() return not c:tree().visible end,'Leader e did not toggle the tree off')
  tree_open(c); local before_help=#c:windows(); c:input('?')
  wait_for(function() return #c:windows()>before_help end,'? did not display real picker help')
  c:input('<Esc>'); pause(50)
  if not c:tree().visible then tree_open(c) elseif c:current().win~=c:tree().window then c:lua([[vim.api.nvim_set_current_win(require('config.explorer').status().window)]]) end
  c:input('/'); wait_for(function() return c:mode()=='i' end,'/ did not focus the real filter input')
  c:input('target'); wait_for(function() local s=c:tree(); return has(s,root..'/folder/deep/target.txt') and not has(s,root..'/main.txt') end,'fd filter did not find a nested target')
  c:input('<Esc>'); wait_for(function() return not c:tree().visible end,'Escape from filter did not close the tree')
  assert(c:current().win==main.win,'Filter Escape did not preserve the editor target')
  tree_open(c); tree_close(c,'q'); tree_open(c); tree_close(c,'<Esc>')
  c:lua([[vim.v.errmsg=''; _G.explorer_test_notify=vim.notify; vim.g.explorer_test_errors={}; vim.notify=function(msg,level,opts) if level==vim.log.levels.ERROR then local t=vim.g.explorer_test_errors; t[#t+1]=tostring(msg); vim.g.explorer_test_errors=t end; return _G.explorer_test_notify(msg,level,opts) end]])
  c:lua([[local e=require('config.explorer'); local p=e.open(); e.close(); assert(p.closed,'Pending explorer was not tracked by the public close API')]])
  pause(100); wait_for(function() return not c:tree().visible end,'Immediate open/close did not finish')
  tree_open(c); c:input('/'); wait_for(function() return c:mode()=='i' end,'Immediate-close filter did not enter input mode')
  c:input('target'); c:lua([[local p=require('config.explorer').status().picker; p:find()]])
  c:input('<Esc>'); pause(100); wait_for(function() return not c:tree().visible end,'Immediate Escape after starting fd filter did not finish')
  local scanner=c:lua([[local result={message=vim.v.errmsg,errors=vim.g.explorer_test_errors}; vim.notify=_G.explorer_test_notify; _G.explorer_test_notify=nil; return result]])
  assert(scanner.message=='' and #scanner.errors==0,'Closing an active explorer scan caused an asynchronous error: '..vim.inspect(scanner))
  print('PASS explorer tree: default closed, 40-column left, ignored/dot toggles, .git exclusion, navigation/open/focus/help/filter/close keys, immediate scan cancellation')

  wait_for(function() return c:lua([[return require('config.search').native_status().status=='ready']]) end,'FFF native dependency unavailable',15000)
  c:lua([[require('config.search').find_files()]])
  assert(c:lua([[return require('fff.picker_ui.picker_ui').state.active]]),'Real FFF UI did not open')
  local matches=c:lua([[local root=...; local rust=require('fff.rust'); assert(rust.wait_for_initial_scan(10000)); local out={}; for _,item in ipairs(require('fff').file_search('',{cwd=root,max_results=1000}).items) do out[#out+1]=item.relative_path end; return out]],{root})
  local indexed={}; for _,path in ipairs(matches) do indexed[path]=true end
  assert(indexed['main.txt'] and not indexed['ignored.txt'] and not indexed['ignored-dir/inside.txt'],'Explorer visibility settings leaked ignored files into the actual FFF index')
  c:input('<Esc>'); wait_for(function() return not c:lua([[return require('fff.picker_ui.picker_ui').state.active]]) end,'FFF UI did not close after Escape')
  print('PASS explorer search isolation: actual FFF index keeps gitignored files excluded')

  c:lua([[require('config.project').activate(...,{restore=false,pick=false})]],{nongit}); local non=c:open(nongit..'/文件 空格.txt')
  local s=tree_open(c); assert(same(s.root,nongit) and has(s,nongit..'/文件 空格.txt'),'Non-Git/Unicode-space project did not browse correctly')
  c:lua([[local s=require('config.explorer').status(); if s.main_win and vim.api.nvim_win_is_valid(s.main_win) then vim.api.nvim_win_close(s.main_win,true) end]])
  c:input('q'); wait_for(function() return not c:tree().visible end,'Sole tree did not close')
  assert(#c:windows()==1 and c:current().ft~='snacks_picker_list','Closing the sole tree did not leave an editor window')
  assert(c:lua([[for _,name in ipairs({'number','relativenumber','cursorline','signcolumn','scrolloff'}) do if vim.api.nvim_get_option_value(name,{win=0})~=vim.api.nvim_get_option_value(name,{scope='global'}) then return false end end; return not vim.wo.winfixwidth and not vim.w.snacks_layout]]),'Sole-tree replacement editor inherited sidebar window options')
  print('PASS explorer project/lifecycle: Unicode-space non-Git roots and sole-tree close preserve an editor')
end
local function terminals(c,root)
  c:lua([[require('config.project').activate(...,{restore=false,pick=false})]],{root}); local code=c:open(root..'/main.txt')
  c:input('<C-j>'); wait_for(function() return c:mode()=='t' end,'Real terminal fixture did not enter terminal mode')
  local t=c:lua([[local s=require('config.terminal').status(); return {session=s.session,buf=vim.api.nvim_get_current_buf(),win=vim.api.nvim_get_current_win()}]])
  c:input('<C-\\><C-n>'); wait_for(function() return c:mode():sub(1,1)=='n' end,'Could not enter terminal-normal mode')
  tree_open(c); assert(c:tree().main_win==code.win,'Explorer failed to retain a terminal-covered main editor window')
  c:input('<C-j>'); pause(80)
  local still=c:lua([[local id=...; for _,s in ipairs(require('config.terminal').sessions()) do if s.id==id then return {session=s,channel=vim.api.nvim_get_chan_info(s.job)} end end]],{t.session.id})
  assert(still and still.session.job==t.session.job and still.session.status=='running' and still.channel.exitcode==-1,'Ctrl-j in the tree stopped or replaced the existing terminal task')
  tree_open(c); c:select(root..'/other.txt'); c:input('<CR>')
  wait_for(function() return c:current().win==code.win and same(c:current().name,root..'/other.txt') and c:mode()=='n' end,'Opening a file did not uncover the main terminal before loading code')
  local sessions=c:lua([[return require('config.terminal').sessions()]])
  assert(#sessions==1 and sessions[1].job==t.session.job and sessions[1].status=='running','Opening code restarted/destroyed the hidden terminal task')
  tree_open(c); tree_close(c)
  c:lua([[require('config.terminal').close(...)]],{t.session.id})
  local manual=c:lua([[
    local buf=vim.api.nvim_create_buf(true,false); vim.api.nvim_set_current_buf(buf)
    local job=vim.fn.jobstart(require('config.machine').load().terminal.shell,{term=true}); assert(job>0); vim.cmd.startinsert()
    return {buf=buf,job=job,win=vim.api.nvim_get_current_win()}
  ]])
  wait_for(function() return c:mode()=='t' end,'Unmanaged native terminal did not enter terminal mode')
  c:input('<C-\\><C-n>'); wait_for(function() return c:mode():sub(1,1)=='n' end,'Unmanaged terminal normal mode did not start')
  tree_open(c); c:select(root..'/main.txt'); c:input('<CR>')
  wait_for(function() return c:current().win==manual.win and same(c:current().name,root..'/main.txt') end,'File did not open over the unmanaged terminal in its original window')
  assert(c:lua([[local job=...; return #require('config.terminal').sessions()==0 and vim.api.nvim_get_chan_info(job).exitcode==-1]],{manual.job}),'Opening a file from an unmanaged terminal spawned or stopped a managed shell')
  tree_open(c); tree_close(c)
  c:lua([[vim.api.nvim_buf_delete(...,{force=true})]],{manual.buf})
  print('PASS explorer terminal: Ctrl-j/file-open preserve managed and unmanaged real jobs; no replacement shell is created')
end
local function interactive_files(c,root)
  local from=root..'/ui-before.txt'; local to=root..'/ui-after.txt'; write(from,{'interactive rename'})
  local before=c:open(from); tree_open(c); c:select(from); c:input('r')
  wait_for(function() return c:mode()=='c' end,'r did not open the real rename input')
  c:input('<C-u>ui-after.txt<CR>')
  wait_for(function() return file_exists(to) and not file_exists(from) end,'Rename input did not execute the real file action')
  wait_for(function() return has(c:tree(),to) end,'Renamed item was not refreshed in the tree')
  c:select(to); c:input('r'); wait_for(function() return c:mode()=='c' end,'Rename cancellation input did not open')
  c:input('<Esc>'); wait_for(function() return c:mode():sub(1,1)=='n' end,'Rename cancellation did not return to the tree')
  assert(file_exists(to) and c:tree().visible,'Cancelling rename changed the file or closed the tree')
  c:input('a'); wait_for(function() return c:mode()=='c' end,'a did not open the real add input')
  c:input('ui-added.txt<CR>'); wait_for(function() return file_exists(root..'/ui-added.txt') end,'Add input did not create a real file')
  c:select(to); c:input('c'); wait_for(function() return c:mode()=='c' end,'c did not open the copy input')
  c:input('ui-copy.txt<CR>'); wait_for(function() return file_exists(root..'/ui-copy.txt') end,'Copy input did not execute')
  c:select(root..'/ui-copy.txt'); c:input('m'); wait_for(function() return c:mode()=='c' end,'m did not open the move/rename input')
  c:input('<C-u>ui-moved.txt<CR>'); wait_for(function() return file_exists(root..'/ui-moved.txt') and not file_exists(root..'/ui-copy.txt') end,'Move input did not execute')
  c:select(to); c:input('a'); wait_for(function() return c:mode()=='c' end,'Directory add input did not open')
  c:input('ui-pasted-dir/<CR>'); wait_for(function() return fn.isdirectory(root..'/ui-pasted-dir')==1 end,'Add directory input did not execute')
  c:select(root..'/ui-moved.txt'); c:input('"ay')
  assert(c:lua([[return vim.fn.getreg('a')]],{}):find('ui-moved.txt',1,true),'y did not copy the selected path to the explicitly named register')
  c:select(root..'/ui-pasted-dir'); c:input('"ap')
  local pasted=root..'/ui-pasted-dir/ui-moved.txt'
  wait_for(function() return file_exists(pasted) end,'p did not copy the named-register source into the selected directory')
  assert(file_exists(root..'/ui-moved.txt'),'Paste moved/deleted the source instead of copying it')
  c:select(to); c:input('c'); wait_for(function() return c:mode()=='c' end,'Copy cancellation input did not open'); c:input('<Esc>')
  wait_for(function() return c:mode():sub(1,1)=='n' end,'Copy cancellation did not return to tree')
  c:input('m'); wait_for(function() return c:mode()=='c' end,'Move cancellation input did not open'); c:input('<Esc>')
  wait_for(function() return c:mode():sub(1,1)=='n' end,'Move cancellation did not return to tree')
  c:input('a'); wait_for(function() return c:mode()=='c' end,'Add cancellation input did not open'); c:input('<Esc>')
  wait_for(function() return c:mode():sub(1,1)=='n' end,'Add cancellation did not return to tree')
  c:lua([[_G.explorer_test_select=Snacks.picker.select; vim.g.explorer_test_confirmations=0; _G.explorer_test_answers={1,2}; Snacks.picker.select=function(items,opts,callback) vim.g.explorer_test_confirmations=vim.g.explorer_test_confirmations+1; local index=table.remove(_G.explorer_test_answers,1); callback(items[index],index) end]])
  c:select(root..'/ui-added.txt'); c:input('d'); pause(30)
  assert(file_exists(root..'/ui-added.txt'),'Cancelled clean deletion still removed its file')
  c:input('d'); wait_for(function() return not file_exists(root..'/ui-added.txt') end,'Confirmed clean deletion did not remove the cache fixture',15000)
  assert(c:lua([[return vim.g.explorer_test_confirmations]])==2,'Clean delete did not request both confirmations')
  c:lua([[Snacks.picker.select=_G.explorer_test_select; _G.explorer_test_select=nil]])
  c:input(' o'); wait_for(function() return c:current().win==before.win end,'File actions lost the main editor target')
  assert(c:current().buf==before.buf and same(c:current().name,to),'Interactive rename replaced the editor buffer')
  local dirty=root..'/ui-dirty-delete.txt'; write(dirty,{'dirty delete disk'})
  c:open(dirty); c:lua([[require('config.autosave').setup({autosave={enabled=false}}); vim.api.nvim_buf_set_lines(0,0,-1,false,{'dirty delete kept'})]])
  local dirtybuf=c:current().buf; tree_open(c); c:select(dirty); c:input('d'); pause(40)
  assert(file_exists(dirty) and c:lua([[return vim.bo[...].modified]],{dirtybuf}),'Dirty d action removed or discarded the source')
  tree_close(c); c:lua([[require('config.autosave').setup({autosave={}})]])
  print('PASS explorer file keys: real a/r/c/m/y/p, prompt cancellation, clean delete confirm/cancel, dirty delete protection, refreshed tree and original editor buffer')
end
local function lsp_rename(c,root)
  if not c:lua([[return vim.lsp.is_enabled('clangd')]]) then print('SKIP explorer real LSP rename: clangd unavailable'); return end
  local from=root..'/ops/lsp-before.cpp'; local to=root..'/ops/lsp-after.cpp'
  write(from,{'int counter = 7;','int read_counter() { return counter; }'})
  local buf=c:open(from).buf
  wait_for(function() return c:lua([[for _,client in ipairs(vim.lsp.get_clients({bufnr=...,name='clangd'})) do if client.initialized then return true end end; return false]],{buf}) end,'Real clangd did not attach to the rename fixture',30000)
  local renamed=c:lua([[
    local from,to=...; vim.g.explorer_lsp_saves={}
    vim.api.nvim_create_autocmd('LspNotify',{callback=function(args) if args.data.method=='textDocument/didSave' then local t=vim.g.explorer_lsp_saves; t[#t+1]=args.data.params.textDocument.uri; vim.g.explorer_lsp_saves=t end end})
    vim.api.nvim_buf_set_lines(0,0,-1,false,{'int counter = 7;','int read_counter() { return counter + 1; }'})
    local ok,err=require('config.explorer_files').rename_path(from,to); return {ok=ok,error=err,buf=vim.api.nvim_get_current_buf(),uri=vim.uri_from_bufnr(0),modified=vim.bo.modified}
  ]],{from,to})
  assert(renamed.ok and renamed.buf==buf,'Real LSP rename did not preserve the dirty code buffer: '..vim.inspect(renamed))
  local connected,connect_error=pcall(wait_for,function()
    return c:lua([[
      local buf=...; local client=vim.lsp.get_clients({bufnr=buf,name='clangd'})[1]; if not client or not client.initialized then return false end
      local uri=vim.uri_from_bufnr(buf); local hover=client:request_sync('textDocument/hover',{textDocument={uri=uri},position={line=0,character=5}},1500,buf)
      local line=vim.api.nvim_buf_get_lines(buf,1,2,true)[1]; local character=assert(line:find('counter',assert(line:find('return',1,true)),true))-1
      local def=client:request_sync('textDocument/definition',{textDocument={uri=uri},position={line=1,character=character}},1500,buf)
      vim.g.explorer_lsp_probe={uri=uri,hover=hover or vim.NIL,definition=def or vim.NIL,client_id=client.id,attached=vim.lsp.buf_is_attached(buf,client.id),saves=vim.g.explorer_lsp_saves}
      if not hover or not hover.result or hover.result==vim.NIL or not def or not def.result or def.result==vim.NIL then return false end
      local locations=def.result.uri and {def.result} or def.result
      for _,loc in ipairs(locations) do local target=loc.uri or loc.targetUri; if target and vim.fs.normalize(vim.uri_to_fname(target))==vim.fs.normalize(vim.uri_to_fname(uri)) then return true end end; return false
    ]],{buf})
  end,'Renamed C++ buffer lost actual clangd hover/definition at its new URI',15000)
  assert(connected,tostring(connect_error)..': '..vim.inspect(c:lua([[return vim.g.explorer_lsp_probe]])))
  wait_for(function() return vim.deep_equal(disk(to),{'int counter = 7;','int read_counter() { return counter + 1; }'}) end,'Renamed LSP fixture did not autosave under its new path')
  assert(not file_exists(from),'LSP autosave recreated the old path')
  assert(c:lua([[local uri=...; for _,saved in ipairs(vim.g.explorer_lsp_saves) do if saved==uri then return true end end; return false]],{renamed.uri}),'Actual LSP didSave did not use the renamed document URI')
  print('PASS explorer LSP rename: real clangd hover/definition and autosave didSave use the new URI with the same buffer')
end
local function files(c,root)
  c:lua([[require('config.project').activate(...,{restore=false,pick=false})]],{root})
  local from=root..'/ops/脏 文件.txt'; local to=root..'/ops/重命名 文件.txt'; write(from,{'original dirty file'})
  local state=c:open(from)
  local result=c:lua([[local from,to=...; vim.api.nvim_buf_set_lines(0,0,-1,false,{'unsaved rename survives'}); local before=vim.fn.undotree().seq_cur; local id=vim.api.nvim_get_current_buf(); local ok,err=require('config.explorer_files').rename_path(from,to); return {ok=ok,error=err,buf=id,valid=vim.api.nvim_buf_is_valid(id),name=vim.api.nvim_buf_get_name(id),modified=vim.bo[id].modified,before=before,after=vim.fn.undotree().seq_cur,lines=vim.api.nvim_buf_get_lines(id,0,-1,true)}]],{from,to})
  assert(result.ok and result.valid and result.buf==state.buf and result.modified and same(result.name,to) and result.before==result.after,'Dirty rename did not preserve the same buffer/undo state: '..vim.inspect(result))
  assert(not file_exists(from) and vim.deep_equal(disk(to),{'original dirty file'}),'Rename prematurely wrote the dirty text')
  c:input('u'); wait_for(function() return vim.deep_equal(c:current().lines,{'original dirty file'}) end,'Undo history was lost during rename')
  c:input('<C-r>'); wait_for(function() return vim.deep_equal(c:current().lines,{'unsaved rename survives'}) end,'Redo history was lost during rename')
  wait_for(function() return vim.deep_equal(disk(to),{'unsaved rename survives'}) end,'Renamed dirty buffer did not resume normal autosave',5000)
  assert(not file_exists(from),'Autosave recreated the obsolete file name')

  if fn.has('win32')==1 then
    local a=root..'/ops/CaseName.txt'; local b=root..'/ops/casename.txt'; write(a,{'case only'})
    local old=c:open(a); local moved=c:lua([[local ok,err=require('config.explorer_files').rename_path(...); return {ok=ok,error=err,name=vim.api.nvim_buf_get_name(0),buf=vim.api.nvim_get_current_buf()}]],{a,b})
    assert(moved.ok and moved.buf==old.buf and moved.name:sub(-12)=='casename.txt','Windows case-only rename failed: '..vim.inspect(moved))
  end
  c:lua([[require('config.autosave').setup({autosave={enabled=false}})]])
  local dir=root..'/ops/directory'; local movedir=root..'/ops/目录 moved'; local a=dir..'/one.txt'; local b=dir..'/nested/two.txt'
  write(a,{'one disk'}); write(b,{'two disk'})
  local abuf=c:open(a).buf; c:lua([[vim.api.nvim_buf_set_lines(0,0,-1,false,{'one modified'})]])
  local bbuf=c:open(b).buf; c:lua([[vim.api.nvim_buf_set_lines(0,0,-1,false,{'two modified'})]])
  local directory=c:lua([[local from,to,a,b=...; local ok,err=require('config.explorer_files').rename_path(from,to); return {ok=ok,error=err,a={name=vim.api.nvim_buf_get_name(a),modified=vim.bo[a].modified},b={name=vim.api.nvim_buf_get_name(b),modified=vim.bo[b].modified}}]],{dir,movedir,abuf,bbuf})
  assert(directory.ok and directory.a.modified and directory.b.modified and same(directory.a.name,movedir..'/one.txt') and same(directory.b.name,movedir..'/nested/two.txt'),'Directory rename did not rebase dirty descendant buffers: '..vim.inspect(directory))
  c:lua([[require('config.autosave').toggle()]])
  wait_for(function() return vim.deep_equal(disk(movedir..'/one.txt'),{'one modified'}) and vim.deep_equal(disk(movedir..'/nested/two.txt'),{'two modified'}) end,'Rebased directory descendants did not autosave',5000)
  assert(not file_exists(dir),'Directory rename recreated the old subtree')

  local conflict=root..'/ops/conflict.txt'; local conflict_to=root..'/ops/conflict-new.txt'; write(conflict,{'original conflict'})
  local conflictbuf=c:open(conflict).buf; c:lua([[vim.api.nvim_buf_set_lines(0,0,-1,false,{'local conflict edit'})]])
  write(conflict,{'external changed contents'})
  wait_for(function() return c:lua([[return require('config.autosave').status(...).buffer.paused]],{conflictbuf}) end,'External conflict did not pause autosave')
  local refused=c:lua([[local from,to,b=...; local ok,err=require('config.explorer_files').rename_path(from,to); return {ok=ok,error=err,paused=require('config.autosave').status(b).buffer.paused,modified=vim.bo[b].modified,name=vim.api.nvim_buf_get_name(b)}]],{conflict,conflict_to,conflictbuf})
  assert(not refused.ok and refused.paused and refused.modified and same(refused.name,conflict) and not file_exists(conflict_to),'Rename washed away an external conflict: '..vim.inspect(refused))
  assert(vim.deep_equal(disk(conflict),{'external changed contents'}),'Conflict rename overwrote the external disk version')

  local occupied=root..'/ops/existing.txt'; write(occupied,{'occupied target'})
  local origin=root..'/ops/origin.txt'; write(origin,{'origin text'}); c:open(origin)
  local function rejects(from_path,to_path)
    local result=c:lua([[local ok,err=require('config.explorer_files').rename_path(...); return {ok=ok,error=err}]],{from_path,to_path})
    assert(not result.ok and type(result.error)=='string','Unsafe rename accepted '..from_path..' -> '..to_path)
  end
  rejects(origin,occupied); rejects(root,root..'-moved'); rejects(origin,root..'/.git/protected.txt'); rejects(root..'/.git/config',root..'/ops/git-config'); rejects(origin,''); rejects(movedir,movedir..'/nested/inside')
  assert(vim.deep_equal(disk(occupied),{'occupied target'}) and vim.deep_equal(disk(origin),{'origin text'}),'Rejected rename changed existing files')
  local copied=root..'/ops/copy.txt'
  local copy=c:lua([[local ok,err=require('config.explorer_files').copy_path(...); return {ok=ok,error=err}]],{origin,copied})
  assert(copy.ok and vim.deep_equal(disk(copied),{'origin text'}) and file_exists(origin),'Copy did not preserve the original file: '..vim.inspect(copy))
  local named=root..'/ops/named-target.txt'; local pending=c:lua([[local p=...; local b=vim.api.nvim_create_buf(true,false); vim.api.nvim_buf_set_name(b,p); vim.api.nvim_buf_set_lines(b,0,-1,false,{'named target unsaved'}); return b]],{named})
  rejects(origin,named)
  local named_copy=c:lua([[local ok,err=require('config.explorer_files').copy_path(...); return {ok=ok,error=err}]],{origin,named})
  assert(not named_copy.ok and not file_exists(named),'Copy wrote under an existing unsaved buffer name: '..vim.inspect(named_copy))
  local dirty=root..'/ops/delete-dirty.txt'; write(dirty,{'delete original'}); local dirtybuf=c:open(dirty).buf
  local deletion=c:lua([[local path=...; vim.api.nvim_buf_set_lines(0,0,-1,false,{'delete dirty retained'}); local ok,err=require('config.explorer_files').delete_paths({path}); return {ok=ok,error=err,valid=vim.api.nvim_buf_is_valid(0),modified=vim.bo.modified,lines=vim.api.nvim_buf_get_lines(0,0,-1,true)}]],{dirty})
  assert(not deletion.ok and deletion.valid and deletion.modified and vim.deep_equal(deletion.lines,{'delete dirty retained'}) and file_exists(dirty),'Delete discarded a dirty buffer: '..vim.inspect(deletion))
  local refused_dir=c:lua([[local ok,err=require('config.explorer_files').delete_paths({...}); return {ok=ok,error=err}]],{root..'/ops'})
  assert(not refused_dir.ok and file_exists(root..'/ops'),'Directory delete ignored modified descendants')
  c:lua([[local a=require('config.autosave'); if a.status().enabled then a.toggle() end]])
  print('PASS explorer file operations: dirty same-buffer undo/redo rename, case-only rename, directory rebasing/autosave, external pause preservation, unsafe target/root/.git rejection, dirty delete protection')
end
local function sessions(c,root)
  c:lua([[require('config.autosave').setup({autosave={enabled=false}}); require('config.project').activate(...,{restore=false,pick=false})]],{root})
  local main=c:open(root..'/main.txt'); c:lua([[vim.cmd('vsplit '..vim.fn.fnameescape(...))]],{root..'/other.txt'})
  local code=c:windows(); tree_open(c)
  assert(c:lua([[return require('config.project').save_session()]]),'Project session did not save while explorer was visible')
  assert(c:tree().visible,'Saving the session closed the live explorer')
  c:shutdown(); assert(c.exited and c.exited.code==0,'Session writer did not exit cleanly')
  local restored=spawn(root,true)
  wait_for(function() return #restored:windows()>=2 end,'Project code splits were not restored')
  assert(not restored:tree().visible,'Session restore reopened the transient explorer')
  assert(restored:lua([[for _,b in ipairs(vim.api.nvim_list_bufs()) do if vim.bo[b].filetype:match('^snacks_picker') then return false end end; return true]]),'Session restored hidden picker buffers')
  local have_main,have_other=false,false; local after=restored:windows(); for _,w in ipairs(after) do have_main=have_main or same(w.name,root..'/main.txt'); have_other=have_other or same(w.name,root..'/other.txt'); assert(not w.name:match('snacks_picker'),'Session restored picker buffers') end
  assert(have_main and have_other and #after==#code,'Project session did not restore only the original code layout: '..vim.inspect({before=code,after=after}))
  print('PASS explorer sessions: live tree survives save; cross-process restore contains code splits without explorer windows/buffers')
end
local function run()
  local root,nongit=fixtures(); local c=spawn(root,false); c:open(root..'/main.txt')
  local case=vim.env.MY_NVIM_EXPLORER_TEST_CASE
  if not case or case=='tree' then tree_keys(c,root,nongit); terminals(c,root) end
  if not case or case=='files' then interactive_files(c,root); lsp_rename(c,root); files(c,root) end
  if not case or case=='session' then sessions(c,root) end
end
vim.schedule(function()
  local ok,err=xpcall(run,debug.traceback)
  for _,c in ipairs(clients) do pcall(c.shutdown,c); if ok and not c.exited then ok,err=false,'Owned test UI did not exit: '..c.pid end end
  if not ok then api.nvim_err_writeln(err); vim.cmd('cquit 1') else print('PASS all explorer integration scenarios'); vim.cmd('qa!') end
end)