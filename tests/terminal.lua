-- nvim --headless -u ./init.lua -c "lua dofile('tests/terminal.lua')"
-- Real noninteractive PTY jobs; Windows output capture needs a parent console.
-- Default PowerShell interaction is checked separately in a real terminal window.
assert(vim.g.my_nvim_ready, 'Load the my-nvim configuration before this test')
local api,fn,uv=vim.api,vim.fn,vim.uv
local terminal=require('config.terminal')
local base=vim.fs.joinpath(fn.stdpath('cache'),'my-nvim-terminal-tests',tostring(uv.os_getpid()))
local roots={vim.fs.joinpath(base,'project-a'),vim.fs.joinpath(base,'project-b')}
local sessions={}
local option_names={'number','relativenumber','signcolumn','cursorline','winfixheight'}
local function shell(ended)
  if fn.has('win32')==1 then
    local command=ended and "[Console]::WriteLine('MY_NVIM_TERMINAL_EXIT'); exit 7"
      or "[Environment]::CurrentDirectory=[IO.Path]::Combine([Environment]::CurrentDirectory,'nested'); [Console]::WriteLine('MY_NVIM_TERMINAL_START'); [Console]::WriteLine('MY_NVIM_CWD='+[Environment]::CurrentDirectory); [Threading.Thread]::Sleep(700); [Console]::WriteLine('MY_NVIM_HIDDEN_OUTPUT'); [Console]::WriteLine('MY_NVIM_CWD_LATER='+[IO.Path]::GetFileName([Environment]::CurrentDirectory)); [Threading.Thread]::Sleep(120000)"
    return {'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-Command',command}
  end
  return {'/bin/sh','-c',ended and "printf '%s\n' 'MY_NVIM_TERMINAL_EXIT'; exit 7"
    or "cd nested; printf '%s\n' 'MY_NVIM_TERMINAL_START'; printf 'MY_NVIM_CWD=%s\n' \"$PWD\"; sleep 0.7; printf '%s\n' 'MY_NVIM_HIDDEN_OUTPUT'; printf 'MY_NVIM_CWD_LATER=%s\n' \"${PWD##*/}\"; exec sleep 120"}
end
local function wait_for(predicate,message,timeout) assert(vim.wait(timeout or 10000,predicate,20),message) end
local function remember(session) if session then sessions[session.id]=session end; return session end
local function lookup(root,id) for _,item in ipairs(terminal.sessions(root)) do if item.id==id then return item end end end
local function current()
  local state=terminal.status()
  assert(state.win==api.nvim_get_current_win() and state.visible,'Current window does not own its visible terminal')
  local session=lookup(state.root,state.active)
  assert(session and session.bufnr==api.nvim_get_current_buf(),'Status does not identify the displayed terminal buffer')
  return remember(session)
end
local function options(win)
  local result={}; for _,name in ipairs(option_names) do result[name]=api.nvim_get_option_value(name,{win=win}) end; return result
end
local function view(win) return api.nvim_win_call(win,fn.winsaveview) end
local function origin(win)
  local buf=api.nvim_win_get_buf(win)
  return {buf=buf,view=view(win),options=options(win),modified=vim.bo[buf].modified,lines=api.nvim_buf_get_lines(buf,0,-1,true)}
end
local function expect_origin(win,before,label)
  assert(api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win)==before.buf,label..': wrong code buffer')
  assert(vim.deep_equal(view(win),before.view),label..': cursor/scroll view was not restored: '..vim.inspect({actual=view(win),expected=before.view}))
  assert(vim.deep_equal(options(win),before.options),label..': editor window options were not restored')
  assert(vim.bo[before.buf].modified==before.modified and vim.deep_equal(api.nvim_buf_get_lines(before.buf,0,-1,true),before.lines),label..': code contents or modified flag changed')
end
local function geometry()
  local result={layout=fn.winlayout(),tabs=api.nvim_list_tabpages(),windows={}}
  for _,win in ipairs(api.nvim_tabpage_list_wins(0)) do result.windows[#result.windows+1]={win,api.nvim_win_get_width(win),api.nvim_win_get_height(win),api.nvim_win_get_position(win)} end
  table.sort(result.windows,function(a,b) return a[1]<b[1] end); return result
end
local function expect_geometry(before) assert(vim.deep_equal(geometry(),before),'Terminal toggle changed window layout, dimensions or tabs') end
local function project(index)
  fn.mkdir(vim.fs.joinpath(roots[index],'nested'),'p')
  local result=vim.system({'git','init','--quiet',roots[index]},{text=true}):wait(10000)
  assert(result.code==0,'Could not create disposable Git project')
end
local function code(root,name)
  local path=vim.fs.joinpath(root,name); local lines={}
  for index=1,180 do lines[index]=('%s line %03d '):format(name,index)..string.rep('x',180) end
  fn.writefile(lines,path); return path
end
local function configure_view(win,line,col,top,left,variant)
  api.nvim_set_current_win(win)
  for name,value in pairs(variant) do api.nvim_set_option_value(name,value,{win=win}) end
  vim.wo[win].wrap=false
  api.nvim_win_set_cursor(win,{line,col})
  fn.winrestview({lnum=line,col=col,topline=top,leftcol=left,curswant=col,coladd=0})
  return origin(win)
end
local function alive(session) assert(fn.jobwait({session.job},0)[1]==-1,'A hidden/shared terminal process was stopped') end
local function output(session,marker)
  for _,line in ipairs(api.nvim_buf_get_lines(session.bufnr,0,-1,false)) do if vim.trim(line)==marker then return true end end
  return false
end
local function cleanup()
  for _,root in ipairs(roots) do for _,item in ipairs(terminal.sessions(root)) do remember(item) end end
  local jobs={}
  for _,item in pairs(sessions) do
    if item.job then jobs[#jobs+1]=item.job end
    if api.nvim_buf_is_valid(item.bufnr) then
      local ok,closed=pcall(terminal.close,item.id)
      if not ok or not closed then pcall(api.nvim_buf_delete,item.bufnr,{force=true}) end
    end
  end
  if #jobs>0 then pcall(fn.jobwait,jobs,5000) end
end
local function run()
  require('config.ai_completion').setup({deepseek={enabled=false}})
  terminal.setup({terminal={shell=shell(false)}})
  vim.o.columns,vim.o.lines=140,46
  project(1); project(2); fn.chdir(roots[1])
  local file1,file2,file3,fileb=code(roots[1],'one.txt'),code(roots[1],'two.txt'),code(roots[1],'three.txt'),code(roots[2],'other.txt')
  vim.cmd.edit(fn.fnameescape(file1)); local win1,buf1=api.nvim_get_current_win(),api.nvim_get_current_buf()
  api.nvim_buf_set_lines(buf1,0,1,false,{'unsaved first source'})
  vim.cmd.vsplit(fn.fnameescape(file2)); local win2=api.nvim_get_current_win()
  local first=configure_view(win1,120,70,109,35,{number=true,relativenumber=true,signcolumn='yes:2',cursorline=true,winfixheight=false})
  local second=configure_view(win2,80,30,70,10,{number=false,relativenumber=false,signcolumn='auto:1-3',cursorline=false,winfixheight=true})
  local layout=geometry()

  api.nvim_set_current_win(win1); vim.cmd.TerminalToggle(); local shared=current()
  expect_geometry(layout); expect_origin(win2,second,'Other window after first toggle')
  assert(terminal.close(999999)==false,'Closing an unknown id unexpectedly closed a selected session')
  assert(api.nvim_get_current_buf()==shared.bufnr,'Unknown-id close changed the current terminal buffer'); alive(shared)
  assert(api.nvim_get_current_win()==win1 and shared.bufnr~=buf1,'Toggle did not replace only the current buffer')
  terminal.toggle('n'); expect_geometry(layout); expect_origin(win1,first,'First window hide'); expect_origin(win2,second,'Other window on hide')
  alive(shared)
  wait_for(function() return output(shared,'MY_NVIM_HIDDEN_OUTPUT') end,'Hidden process did not continue producing output')
  wait_for(function() return output(shared,'MY_NVIM_CWD_LATER=nested') end,'Hidden process lost its own working directory')
  terminal.toggle('n'); assert(current().job==shared.job and current().bufnr==shared.bufnr,'Reopening restarted the hidden shell')

  api.nvim_set_current_win(win2); assert(not terminal.status().visible,'Status reported a terminal from a different window')
  terminal.toggle('n'); assert(current().id==shared.id,'Same project did not share the selected session across windows')
  assert(api.nvim_win_get_buf(win1)==shared.bufnr,'Opening the second terminal replaced the first window')
  expect_geometry(layout)
  terminal.toggle('n'); expect_origin(win2,second,'Second independent origin')
  assert(api.nvim_win_get_buf(win1)==shared.bufnr,'Hiding the second view hid another terminal window')
  api.nvim_set_current_win(win1); terminal.toggle('n'); expect_origin(win1,first,'First independent origin')

  terminal.toggle('n'); local another=remember(terminal.new())
  assert(another.id~=shared.id and another.job~=shared.job,'New did not create another project session')
  terminal.select(shared.id); terminal.select(another.id); terminal.toggle('n')
  expect_origin(win1,first,'New/select kept the original source'); expect_origin(win2,second,'New/select other window'); expect_geometry(layout)

  -- Exercise the installed Telescope picker and its real vertical-selection callback.
  terminal.select()
  local prompt
  wait_for(function() for _,win in ipairs(api.nvim_list_wins()) do local buf=api.nvim_win_get_buf(win); if vim.bo[buf].filetype=='TelescopePrompt' then prompt=buf; return true end end end,'Terminal picker did not render')
  local picker=require('telescope.actions.state').get_current_picker(prompt)
  wait_for(function() return picker.manager and picker.manager:num_results()>=2 end,'Terminal picker did not list sessions')
  picker:set_selection(picker:get_row(1)); local picked=picker:get_selection().value.id
  require('telescope.actions').select_vertical(prompt)
  wait_for(function() return terminal.status().visible and terminal.status().active==picked end,'Telescope did not replace the original target window')
  assert(api.nvim_get_current_win()==win1,'Telescope selection changed the target window'); expect_geometry(layout)
  terminal.toggle('n'); expect_origin(win1,first,'Picker return source')

  -- A different project uses a different process in its own existing window.
  api.nvim_set_current_win(win1); terminal.select(shared.id)
  api.nvim_set_current_win(win2); vim.cmd.edit(fn.fnameescape(fileb)); local other_origin=origin(win2)
  terminal.toggle('n'); local other=current()
  assert(other.job~=shared.job and other.root~=shared.root,'Different projects shared their shell process')
  assert(api.nvim_win_get_buf(win1)==shared.bufnr,'Other project disturbed the first terminal view')
  terminal.toggle('n'); expect_origin(win2,other_origin,'Other project source')
  vim.cmd.edit(fn.fnameescape(file2)); second=configure_view(win2,80,30,70,10,second.options)
  terminal.select(shared.id)

  -- Session saving projects each visible terminal back onto its own code origin.
  local focus=api.nvim_get_current_win(); local terminal_views={view(win1),view(win2)}
  local value=terminal.with_editors(function()
    expect_origin(win1,first,'with_editors first'); expect_origin(win2,second,'with_editors second')
    assert(api.nvim_get_current_win()==focus,'with_editors moved focus before its callback')
    return 'editor-snapshot'
  end)
  assert(value=='editor-snapshot','with_editors lost the callback return value')
  assert(api.nvim_get_current_win()==focus and api.nvim_win_get_buf(win1)==shared.bufnr and api.nvim_win_get_buf(win2)==shared.bufnr,'with_editors did not restore both terminal views')
  assert(vim.deep_equal(view(win1),terminal_views[1]) and vim.deep_equal(view(win2),terminal_views[2]),'with_editors changed terminal scroll views')
  local ok,err=pcall(terminal.with_editors,function() error('expected-editor-callback-failure') end)
  assert(not ok and tostring(err):find('expected-editor-callback-failure',1,true),'with_editors hid a callback error')
  assert(api.nvim_get_current_win()==focus and api.nvim_win_get_buf(win1)==shared.bufnr and api.nvim_win_get_buf(win2)==shared.bufnr,'with_editors failed its finally restoration')
  expect_geometry(layout); alive(shared)

  assert(terminal.close(shared.id),'Close failed for a session shown in two windows')
  expect_origin(win1,first,'Close restored first source'); expect_origin(win2,second,'Close restored second source')
  assert(api.nvim_get_current_win()==focus,'Close changed the caller focus'); expect_geometry(layout)
  wait_for(function() return fn.jobwait({shared.job},0)[1]~=-1 end,'Close left the PTY process running')
  alive(another)

  -- A manual buffer switch becomes the next source; old origin metadata must expire.
  api.nvim_set_current_win(win1); terminal.select(another.id)
  vim.cmd.edit(fn.fnameescape(file3)); local third_buf=api.nvim_get_current_buf()
  wait_for(function() return not terminal.status().visible and vim.deep_equal(options(win1),first.options) end,'Manual buffer switch kept terminal ownership/options')
  local third=configure_view(win1,50,22,40,5,first.options)
  terminal.toggle('n'); terminal.toggle('n'); expect_origin(win1,third,'Manual buffer next origin')
  expect_origin(win2,second,'Manual buffer other window'); alive(another)

  terminal.toggle('n'); api.nvim_win_close(win1,true)
  alive(another); assert(api.nvim_win_is_valid(win2),'Closing a terminal window closed another editor')
  api.nvim_set_current_win(win2); expect_origin(win2,second,'WinClose other source')
  vim.cmd.vsplit(fn.fnameescape(file3)); local win3=api.nvim_get_current_win()
  third=configure_view(win3,50,22,40,5,first.options)
  terminal.select(another.id); terminal.toggle('n'); expect_origin(win3,third,'New window after WinClose')
  local after_close=geometry()

  api.nvim_buf_set_lines(second.buf,0,1,false,{'unsaved second source'})
  api.nvim_buf_set_lines(third.buf,0,1,false,{'unsaved third source'})
  second,third=origin(win2),origin(win3)
  api.nvim_set_current_win(win2); terminal.select(another.id)
  api.nvim_set_current_win(win3); terminal.select(another.id)
  local before_delete_tab=api.nvim_get_current_tabpage()
  vim.cmd('bdelete! '..another.bufnr)
  -- Native :bdelete may close duplicate views of one buffer. Retain that native
  -- command behavior, but never lose hidden code or leave stale terminal owners.
  wait_for(function()
    for _,entry in ipairs({{win2,second},{win3,third}}) do
      if api.nvim_win_is_valid(entry[1]) and api.nvim_win_get_buf(entry[1])~=entry[2].buf then return false end
    end
    return not lookup(roots[1],another.id)
  end,'Manual BufDelete did not restore the surviving source windows')
  local reconciled=false; vim.schedule(function() reconciled=true end)
  wait_for(function() return reconciled end,'Scheduled native buffer-delete cleanup did not finish')
  for _,entry in ipairs({{win2,second},{win3,third}}) do
    local win,before=entry[1],entry[2]
    if api.nvim_win_is_valid(win) then
      assert(api.nvim_win_get_buf(win)==before.buf and vim.deep_equal(options(win),before.options),'BufDelete surviving source/options were not restored')
      assert(vim.deep_equal(api.nvim_win_get_cursor(win),{before.view.lnum,before.view.col}),'BufDelete surviving cursor was not restored')
      -- Native duplicate-view closure resizes/recenters the survivor; its scroll
      -- offsets can legitimately differ. Ordinary toggle/close remain exact.
    end
    assert(api.nvim_buf_is_valid(before.buf) and vim.bo[before.buf].modified
      and vim.deep_equal(api.nvim_buf_get_lines(before.buf,0,-1,true),before.lines),'BufDelete lost code from a closed duplicate window')
  end
  assert(api.nvim_get_current_tabpage()==before_delete_tab,'BufDelete unexpectedly closed the tab')
  local survivor=api.nvim_win_is_valid(win3) and win3 or win2
  assert(api.nvim_win_is_valid(survivor),'BufDelete left no editing window')
  api.nvim_set_current_win(survivor)
  local survivor_origin=origin(survivor); local recovered_layout=geometry()
  terminal.toggle('n'); terminal.toggle('n'); expect_origin(survivor,survivor_origin,'Toggle after BufDelete'); expect_geometry(recovered_layout)

  -- A sole window must never be closed or replaced with an unrelated scratch buffer.
  for _,win in ipairs(api.nvim_tabpage_list_wins(0)) do if win~=survivor then api.nvim_win_close(win,true) end end
  api.nvim_set_current_win(survivor)
  local sole=origin(survivor); local sole_layout=geometry(); local sole_tab=api.nvim_get_current_tabpage()
  terminal.toggle('n'); local last=current(); terminal.toggle('n')
  expect_origin(survivor,sole,'Sole-window return'); expect_geometry(sole_layout)
  assert(api.nvim_get_current_tabpage()==sole_tab and #api.nvim_tabpage_list_wins(0)==1,'Toggle closed the sole window/tab')
  alive(last)

  terminal.setup({terminal={shell=shell(true)}})
  local ended=remember(terminal.new())
  wait_for(function() local item=lookup(roots[1],ended.id); return item and item.status=='ended' and item.exit_code==7 end,'Exited session did not retain its exit code/output')
  assert(output(ended,'MY_NVIM_TERMINAL_EXIT'),'Exited terminal lost its output')
  terminal.toggle('n'); expect_origin(survivor,sole,'Exited session return source')
  terminal.toggle('n'); assert(current().id==ended.id and current().job==ended.job,'Reopening exited output started another job')
  terminal.toggle('n'); expect_origin(survivor,sole,'Reopened exited source')
  assert(vim.bo[buf1].modified and api.nvim_buf_get_lines(buf1,0,1,true)[1]=='unsaved first source','Terminal lifecycle lost unsaved code')
  assert(fn.readfile(file1)[1]~='unsaved first source','Terminal lifecycle wrote unsaved code to disk')
  print('PASS terminal: same-window layout, background job/cwd, per-window buffers/views/options, shared sessions, new/select origins, real Telescope, project isolation, with_editors finally, close/WinClose/BufDelete, sole window, exited output')
end
vim.schedule(function()
  local ok,err=xpcall(run,debug.traceback); cleanup()
  if not ok then api.nvim_err_writeln(err); vim.cmd('cquit 1') else vim.cmd('qa!') end
end)
