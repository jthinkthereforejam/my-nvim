-- nvim --headless -i NONE -u ./init.lua -c "lua dofile('tests/git.lua')"
-- Real Gitsigns/Telescope/diff windows and disk/index operations in a cache Git repository.
assert(vim.g.my_nvim_ready, 'Load the my-nvim configuration before this test')
require('config.autosave').setup({ autosave = { enabled = false } })
local api, fn, uv = vim.api, vim.fn, vim.uv
local config_root = assert(vim.g.my_nvim_root)
local base = vim.fs.joinpath(fn.stdpath('cache'), 'my-nvim-git-tests', tostring(uv.os_getpid()) .. '-' .. tostring(uv.hrtime()))
local root = base .. "/项目 空格"
fn.mkdir(root, 'p')
local children = {}
local function pause(ms) vim.wait(ms, function() return false end, 10) end
local function wait_for(predicate, message, timeout)
  -- Nested RPC waits can reset vim.wait's timeout accounting; use wall time.
  local deadline = uv.hrtime() + (timeout or 10000) * 1000000
  repeat if predicate() then return end; pause(15) until uv.hrtime() >= deadline
  error(message, 2)
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
local function same_path(a,b)
  if not a or not b then return false end
  a,b=vim.fs.normalize(a):gsub('[/\\]+$',''),vim.fs.normalize(b):gsub('[/\\]+$','')
  if fn.has('win32')==1 then a,b=a:lower(),b:lower() end
  return a==b
end
local function spawn(restore)
  fn.mkdir(base .. '/undo', 'p')
  local early = ('lua vim.g.my_nvim_root=%q; vim.opt.rtp:prepend(%q); local m=require("config.machine").load(); m.autosave={enabled=false}; m.deepseek={enabled=false}; m.terminal={shell=vim.fn.has("win32")==1 and {"powershell.exe","-NoLogo","-NoProfile","-NonInteractive","-Command","[Threading.Thread]::Sleep(120000)"} or {"/bin/sleep","120"}}; m.project=vim.tbl_extend("force",m.project or {},{state_dir=%q}); vim.o.swapfile=false; vim.opt.undodir=%q')
    :format(config_root, config_root, base .. '/state', base .. '/undo')
  local environment, env = require('config.project_native').child_env(), {}
  for key, value in pairs(environment) do if key:upper() ~= 'DEEPSEEK_API_KEY' then env[#env + 1] = key .. '=' .. value end end
  local c = { stdin = uv.new_pipe(false), stdout = uv.new_pipe(false), stderr = uv.new_pipe(false), serial = 0, responses = {}, errors = {} }
  children[#children + 1] = c
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
    assert(not self.exited, 'Owned Git UI exited: ' .. table.concat(self.errors))
    self.stdin:write(vim.mpack.encode({ 0, id, method, args or {} }))
    local waited = pcall(wait_for, function() return self.responses[id] or self.protocol_error or self.exited end, 'Git RPC timeout: ' .. method, 12000)
    if not waited then
      self.serial=self.serial+1; local probe=self.serial
      self.stdin:write(vim.mpack.encode({0,probe,'nvim_get_mode',{}}))
      vim.wait(500,function() return self.responses[probe]~=nil end,10)
      local mode=self.responses[probe]
      self.stdin:write(vim.mpack.encode({2,'nvim_input',{mode and mode[4] and mode[4].mode=='rm' and 'q<CR>' or '<CR>'}})); pause(100)
      self.serial=self.serial+1; local messages=self.serial
      self.stdin:write(vim.mpack.encode({0,messages,'nvim_exec_lua',{'return vim.api.nvim_exec2("messages",{output=true}).output',{}}}))
      vim.wait(1000,function() return self.responses[messages]~=nil end,10)
      error('Git RPC timeout '..method..': '..vim.inspect({mode=mode,messages=self.responses[messages]}))
    end
    assert(not self.protocol_error, self.protocol_error)
    local response = self.responses[id]; self.responses[id] = nil
    assert(response, 'Owned Git UI exited during ' .. method .. ': ' .. table.concat(self.errors))
    assert(response[3] == nil or response[3] == vim.NIL, 'Git API error: ' .. vim.inspect(response[3]))
    return response[4]
  end
  function c:lua(source, args) return self:request('nvim_exec_lua', { source, args or {} }) end
  function c:input(keys) return self:request('nvim_input', { keys }) end
  function c:lines() return self:lua('return vim.api.nvim_buf_get_lines(0,0,-1,true)') end
  function c:open(name, lines, filetype)
    local path = root .. '/' .. name; if lines then write(path, lines) end
    self:lua([[local path,ft=...; vim.cmd('edit '..vim.fn.fnameescape(path)); vim.b.completion=false; if ft then vim.bo.filetype=ft end]], { path, filetype })
    wait_for(function() return self:lua('return vim.api.nvim_get_mode().mode') == 'n' end, 'Fixture did not enter Normal mode')
    return path
  end
  function c:shutdown()
    if not self.exited then
      pcall(self.lua, self, [[require('config.autosave').setup({autosave={enabled=false}}); for _,s in ipairs(require("config.terminal").sessions()) do require("config.terminal").close(s.id) end; for _,c in ipairs(vim.lsp.get_clients()) do c:stop(true) end]])
      pcall(self.stdin.write, self.stdin, vim.mpack.encode({ 2, 'nvim_command', { 'qa!' } }))
      vim.wait(5000, function() return self.exited ~= nil end, 10)
    end
    if not self.exited then pcall(self.handle.kill, self.handle, 15); vim.wait(3000, function() return self.exited ~= nil end, 10) end
    close(self.stdin); close(self.stdout); close(self.stderr); close(self.handle)
  end
  c:request('nvim_ui_attach', { 150, 45, { ext_linegrid = true, rgb = true } })
  wait_for(function() return c:lua('return vim.g.my_nvim_ready==true') end, 'Configuration did not initialize')
  c:lua([[
    _G.git_test_notices={}
    vim.notify=function(message,level) _G.git_test_notices[#_G.git_test_notices+1]={message=tostring(message),level=level} end
    vim.o.hidden=true
    local root,restore=...; require('config.project').activate(root,{restore=restore,pick=false})
  ]], { root, restore == true })
  return c
end
local function git(args)
  local command = { 'git', '-C', root, '-c', 'core.autocrlf=false', '-c', 'core.hooksPath=' .. base .. '/no-hooks' }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true, env = { GIT_DIR = root .. '/.git', GIT_WORK_TREE = root, GIT_INDEX_FILE = root .. '/.git/index' } }):wait(10000)
  assert(result.code == 0, 'Fixture Git command failed: ' .. table.concat(args, ' ') .. ': ' .. (result.stderr or ''))
  return result.stdout or ''
end
local function index_hash()
  local path = root .. '/.git/index'; local file = assert(uv.fs_open(path, 'r', 0))
  local data = assert(uv.fs_read(file, assert(uv.fs_fstat(file)).size, 0)); uv.fs_close(file)
  return fn.sha256(data)
end
local head, disk = {}, {}
local function fixture()
  assert(vim.system({ 'git', 'init', '--quiet', root }, { text = true }):wait(10000).code == 0)
  for line = 1, 28 do head[line] = ('HEAD line %02d'):format(line) end
  write(root .. '/main 代码.txt', head)
  write(root .. '/staged.txt', { 'staged HEAD' })
  write(root .. '/other.txt', { 'other HEAD' })
  write(root .. '/deleted.txt', { 'deleted HEAD' })
  write(root .. '/.gitignore', { 'ignored.txt' })
  git({ 'add', '--', '.' }); git({ '-c', 'user.name=Neovim integration test', '-c', 'user.email=nvim-test@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'fixture HEAD' })
  disk = vim.deepcopy(head); disk[8] = 'DISK line 08'
  write(root .. '/main 代码.txt', disk)
  write(root .. '/staged.txt', { 'staged INDEX' }); write(root .. '/staged-new.txt', { 'new staged disk' }); git({ 'add', '--', 'staged.txt', 'staged-new.txt' })
  write(root .. '/untracked.txt', { 'untracked disk' }); write(root .. '/ignored.txt', { 'ignored disk' })
  assert(uv.fs_unlink(root .. '/deleted.txt'))
end
local function snapshot(c)
  return c:lua([[
    local api=vim.api; local wins={}
    for _,w in ipairs(api.nvim_tabpage_list_wins(0)) do
      local b=api.nvim_win_get_buf(w); local options={}
      for _,o in ipairs({'diff','scrollbind','cursorbind','foldmethod','foldenable','foldlevel','foldcolumn','wrap','scrolloff','winfixwidth'}) do options[o]=api.nvim_get_option_value(o,{win=w}) end
      wins[tostring(w)]={win=w,buf=b,name=api.nvim_buf_get_name(b),width=api.nvim_win_get_width(w),height=api.nvim_win_get_height(w),position=api.nvim_win_get_position(w),options=options}
    end
    return {win=api.nvim_get_current_win(),buf=api.nvim_get_current_buf(),layout=vim.fn.winlayout(),wins=wins,cwd=vim.fn.getcwd()}
  ]])
end
local function marks(c)
  return c:lua([[
    local result={}; local namespaces=vim.api.nvim_get_namespaces()
    for _,name in ipairs({'gitsigns_signs_','my-nvim-git-newfiles'}) do
      local ns=namespaces[name]
      if ns then vim.list_extend(result,vim.api.nvim_buf_get_extmarks(0,ns,0,-1,{details=true})) end
    end
    return result
  ]])
end
local function hunks(c) return c:lua('return require("gitsigns").get_hunks(0) or {}') end
local function signs(c)
  c:open('main 代码.txt')
  wait_for(function() return #hunks(c) > 0 end, 'Disk difference did not attach Gitsigns')
  local edited = vim.deepcopy(disk); edited[3] = 'UNSAVED line 03'; table.insert(edited, 12, 'UNSAVED inserted line'); table.remove(edited, 23)
  c:lua('vim.api.nvim_buf_set_lines(0,0,-1,false,...)', { edited })
  wait_for(function() return #hunks(c) >= 4 and #marks(c) >= 4 end, 'Unsaved changes/addition/deletion were not displayed against HEAD')
  same(fn.readfile(root .. '/main 代码.txt'), disk, 'Gitsigns saved unsaved buffer changes')
  local types = {}; for _,h in ipairs(hunks(c)) do types[h.type] = true end
  assert(types.add and types.change and types.delete, 'Actual hunks did not include add/change/delete: ' .. vim.inspect(types))
  c:lua([[
    _G.git_test_diag=vim.api.nvim_create_namespace('my-nvim-git-test-diagnostic')
    vim.diagnostic.set(_G.git_test_diag,0,{{lnum=2,col=0,message='fixture diagnostic',severity=vim.diagnostic.severity.ERROR}})
  ]])
  local overlap = c:lua([[
    local gs=vim.api.nvim_get_namespaces().gitsigns_signs_; local ds=vim.diagnostic.get_namespace(_G.git_test_diag).user_data.sign_ns
    local function has(ns) if not ns then return false end; for _,m in ipairs(vim.api.nvim_buf_get_extmarks(0,ns,0,-1,{details=true})) do if m[2]==2 and m[4].sign_text then return true end end; return false end
    local colors={}; for _,name in ipairs({'GitSignsAdd','GitSignsChange','GitSignsDelete'}) do colors[#colors+1]=vim.api.nvim_get_hl(0,{name=name,link=false}).fg end
    return {git=has(gs),diagnostic=has(ds),signcolumn=vim.wo.signcolumn,colors=colors}
  ]])
  assert(overlap.git and overlap.diagnostic and overlap.signcolumn == 'yes:2', 'Git and diagnostics did not coexist in two fixed sign columns: ' .. vim.inspect(overlap))
  assert(#overlap.colors == 3 and overlap.colors[1] ~= overlap.colors[2] and overlap.colors[2] ~= overlap.colors[3], 'Git sign colors are missing or indistinguishable')
  for _,m in ipairs(marks(c)) do assert(({ ['+']=true, ['~']=true, ['_']=true, ['^']=true })[vim.trim(m[4].sign_text or '')], 'Git sign requires a non-ASCII glyph') end
  c:input('gg]c'); wait_for(function() return c:lua('return vim.fn.line(".")') == 3 end, ']c did not navigate to the first unsaved hunk')
  c:input(']c'); wait_for(function() return c:lua('return vim.fn.line(".")') == 8 end, ']c did not navigate to the next HEAD hunk')
  c:input('[c'); wait_for(function() return c:lua('return vim.fn.line(".")') == 3 end, '[c did not navigate back')
  c:input(' gp'); wait_for(function() return c:lua([[for _,w in ipairs(vim.api.nvim_list_wins()) do if vim.api.nvim_win_get_config(w).relative~='' then return true end end; return false]]) end, 'Hunk preview did not open')
  c:input('<Esc>'); c:lua([[for _,w in ipairs(vim.api.nvim_list_wins()) do if vim.api.nvim_win_get_config(w).relative~='' then vim.api.nvim_win_close(w,true) end end]])
  c:input(' gt'); wait_for(function() return #marks(c) == 0 end, 'Git sign toggle did not hide signs')
  c:input(' gt'); wait_for(function() return #marks(c) > 0 end, 'Git sign toggle did not restore signs')
  c:open('staged.txt'); wait_for(function() return #hunks(c) > 0 end, 'Staged-only content was not compared with HEAD')
  c:open('staged-new.txt'); wait_for(function() return #marks(c) > 0 end, 'A new index-tracked file missing from HEAD did not receive add signs')
  c:open('untracked.txt'); wait_for(function() return #marks(c) > 0 end, 'Untracked file did not receive add signs')
  for _,m in ipairs(marks(c)) do assert(vim.trim(m[4].sign_text or '')=='+','Untracked content is not shown as additions') end
  c:open('ignored.txt'); pause(300); assert(#marks(c) == 0, 'Ignored file was attached as untracked')
  local nongit = write(base .. '/nongit/plain.txt', { 'non Git text' }); c:lua([[vim.cmd('edit '..vim.fn.fnameescape(...))]], { nongit }); pause(200)
  assert(#marks(c) == 0, 'Non-Git buffer received Git signs')
  c:lua([[require('config.git').preview()]]); assert(c:lua('return vim.api.nvim_get_mode().blocking') == false, 'Non-Git preview blocked the UI')
  c:open('main 代码.txt'); same(c:lines(), edited, 'Switching files lost unsaved Git buffer contents')
  print('PASS Git signs: HEAD/staged/unsaved/add/delete/untracked, ignored/non-Git, diagnostics/colors, navigation/preview/toggle')
  return edited
end
local function picker(c)
  local state = c:lua([[
    for _,w in ipairs(vim.api.nvim_list_wins()) do
      local b=vim.api.nvim_win_get_buf(w)
      if vim.bo[b].filetype=='TelescopePrompt' then
        local p=require('telescope.actions.state').get_current_picker(b); local selected=p:get_selection(); local entries={}
        if p.manager then for i=1,p.manager:num_results() do local e=p.manager:get_entry(i); entries[#entries+1]={value=e.value,status=e.status} end end
        local preview=p.previewer and p.previewer.state and p.previewer.state.bufnr
        return {prompt=b,entries=entries,selected=selected and selected.value,preview=preview and vim.api.nvim_buf_is_valid(preview) and vim.api.nvim_buf_get_lines(preview,0,-1,true) or {},mode=vim.api.nvim_get_mode().mode}
      end
    end
  ]])
  return state~=vim.NIL and state or nil
end
local function select(c,path)
  wait_for(function() return c:lua([[
    local wanted=...; local p=require('telescope.actions.state').get_current_picker(vim.api.nvim_get_current_buf())
    if not p or not p.manager then return false end
    for i=1,p.manager:num_results() do if p.manager:get_entry(i).value==wanted then p:set_selection(p:get_row(i)); return p:get_selection().value==wanted end end
    return false
  ]], { path }) end, 'Git status entry was not selectable: ' .. path)
end
local function changes(c,edited)
  local index = index_hash(); local cwd = c:lua('return vim.fn.getcwd()')
  c:input(' gs'); wait_for(function() local p=picker(c); return p and #p.entries >= 4 end, 'Telescope Git status did not list the fixture changes')
  local initial = picker(c); local found={}; for _,entry in ipairs(initial.entries) do found[entry.value]=entry.status end
  assert(found['main 代码.txt'] and found['staged.txt'] and found['untracked.txt'] and found['deleted.txt'] and not found['ignored.txt'], 'Git status entries did not reflect disk/index/ignore state: ' .. vim.inspect(found))
  c:input('<Tab>'); wait_for(function() return picker(c).selected ~= initial.selected end, 'Insert-mode Tab did not move Git status selection')
  same(index_hash(), index, 'Insert-mode Tab staged a file')
  c:input('<Esc>'); wait_for(function() return picker(c) and picker(c).mode == 'n' end, 'Status picker did not enter Normal mode')
  local before = picker(c).selected; c:input('<Tab>'); wait_for(function() return picker(c).selected ~= before end, 'Normal-mode Tab did not move Git status selection')
  same(index_hash(), index, 'Normal-mode Tab staged a file')
  select(c, 'main 代码.txt')
  wait_for(function() local text=table.concat(picker(c).preview,'\n'); return text:find('DISK line 08',1,true) and text:find('HEAD line 08',1,true) end, 'Git status preview was not the real HEAD-to-disk diff')
  assert(not table.concat(picker(c).preview,'\n'):find('UNSAVED line 03',1,true), 'Disk status preview silently saved/read unsaved buffer contents')
  c:input('<CR>'); wait_for(function() return picker(c)==nil and same_path(c:lua('return vim.api.nvim_buf_get_name(0)'),root..'/main 代码.txt') end, 'Enter did not open the selected file')
  same(c:lines(), edited, 'Status Enter replaced unsaved buffer text')
  same(c:lua('return vim.fn.getcwd()'), cwd, 'Git status picker changed cwd')
  same(fn.readfile(root .. '/main 代码.txt'), disk, 'Git status picker automatically saved the buffer')
  same(index_hash(), index, 'Git status picker modified the index')
  print('PASS Git status: real HEAD/disk preview, i/n Tab navigation without staging, Enter preserves buffer/cwd/disk/index')
end
local function diff(c,edited)
  c:lua([[vim.wo.wrap=true; vim.wo.foldmethod='manual'; vim.wo.scrolloff=3; require('config.terminal').new(); vim.cmd.stopinsert(); require('config.terminal').toggle()]])
  wait_for(function() return c:lua('return vim.bo.buftype') == '' end, 'Fixture terminal did not return to its code buffer')
  local session = c:lua('return require("config.terminal").sessions()[1]'); assert(session and session.status=='running', 'Fixture terminal job did not survive hiding')
  c:input('<Esc>'); wait_for(function() return c:lua('return vim.api.nvim_get_mode().mode')=='n' end,'Terminal setup did not leave Normal mode')
  c:lua([[require('config.explorer').open()]])
  wait_for(function() return c:lua('return require("config.explorer").status().visible') end, 'Tree did not open for diff coexistence')
  c:lua([[local e=require('config.explorer').status(); vim.api.nvim_set_current_win(e.main_win)]])
  local before = snapshot(c)
  c:input(' gd'); wait_for(function() return c:lua('return require("config.git_diff").status().visible') end, 'HEAD diff did not open')
  local view = c:lua([[
    local s=require('config.git_diff').status(); return {visible=s.visible,left=s.left_win,right=s.right_win,buf=s.buf,snapshot=s.snapshot,
      left_lines=vim.api.nvim_buf_get_lines(s.snapshot,0,-1,true),right_lines=vim.api.nvim_buf_get_lines(s.buf,0,-1,true),
      left_readonly=vim.bo[s.snapshot].readonly,left_modifiable=vim.bo[s.snapshot].modifiable,left_listed=vim.bo[s.snapshot].buflisted,
      current=vim.api.nvim_get_current_win(),rightbuf=vim.api.nvim_win_get_buf(s.right_win),leftpos=vim.api.nvim_win_get_position(s.left_win),rightpos=vim.api.nvim_win_get_position(s.right_win),leftdiff=vim.wo[s.left_win].diff,rightdiff=vim.wo[s.right_win].diff}
  ]])
  assert(view.buf==before.buf and view.rightbuf==before.buf and view.right==before.win and view.current==before.win, 'Diff did not retain the current editable buffer/window')
  same(view.left_lines, head, 'Left diff snapshot was not actual HEAD')
  same(view.right_lines, edited, 'Right diff lost unsaved text')
  assert(view.left_readonly and not view.left_modifiable and not view.left_listed and view.leftdiff and view.rightdiff and view.leftpos[2]<view.rightpos[2], 'Diff snapshot is not a readonly left pane')
  assert(c:lua('return require("config.explorer").status().visible'), 'Diff closed the tree')
  -- Direct-file launches can leave cwd outside Git; a focused HEAD snapshot
  -- must derive GitChanges from its source, without an explicit project root.
  c:lua([[
    _G.git_test_direct_launch={root=require('config.project').root,cwd=vim.fn.getcwd()}
    require('config.project').root=function() return nil end
    vim.cmd('cd '..vim.fn.fnameescape(...))
    vim.api.nvim_set_current_win(require('config.git_diff').status().left_win)
  ]],{base..'/nongit'})
  local rooted,root_error=xpcall(function()
    c:input(' gs')
    wait_for(function()
      local p=picker(c); if not p then return false end
      local main,staged=false,false
      for _,entry in ipairs(p.entries) do main=main or entry.value=='main 代码.txt'; staged=staged or entry.value=='staged.txt' end
      return main and staged
    end,'GitChanges from HEAD pane lost the direct-file source repository')
    c:lua([[
      for _,w in ipairs(vim.api.nvim_list_wins()) do
        local b=vim.api.nvim_win_get_buf(w)
        if vim.bo[b].filetype=='TelescopePrompt' then require('telescope.actions').close(b); break end
      end
    ]])
    wait_for(function() return picker(c)==nil end,'Direct-file Git picker did not close')
  end,debug.traceback)
  c:lua([[
    local saved=_G.git_test_direct_launch
    require('config.project').root=saved.root
    vim.cmd('cd '..vim.fn.fnameescape(saved.cwd))
    _G.git_test_direct_launch=nil
    vim.api.nvim_set_current_win(...)
  ]],{before.win})
  assert(rooted,root_error)
  assert(c:lua('return require("config.project").save_session()'), 'Session could not save while HEAD diff/tree were visible')
  assert(c:lua('return require("config.git_diff").status().visible'), 'Saving a session closed the live diff')
  c:input(' gd'); wait_for(function() return not c:lua('return require("config.git_diff").status().visible') end, 'Diff toggle did not close')
  same(snapshot(c), before, 'Diff toggle did not restore original window geometry/options/buffers')
  c:input(' gd'); wait_for(function() return c:lua('return require("config.git_diff").status().visible') end, 'Diff did not reopen')
  c:lua([[local s=require('config.git_diff').status(); vim.api.nvim_win_close(s.left_win,true)]])
  wait_for(function() return not c:lua('return require("config.git_diff").status().visible') end, 'Manually closing HEAD pane left an owned diff')
  same(snapshot(c), before, 'Manual diff close did not restore window geometry/options')
  c:input(' gd'); wait_for(function() return c:lua('return require("config.git_diff").status().visible') end, 'Diff did not reopen before buffer switch')
  c:open('other.txt'); wait_for(function() return not c:lua('return require("config.git_diff").status().visible') end, 'Switching the source buffer did not close the owned diff')
  c:open('main 代码.txt')
  assert(c:lua('return not vim.wo.diff and vim.wo.foldmethod~="diff"'), 'Returning to the source buffer resurrected cached native diff options')
  same(c:lines(),edited,'Switching away from and back to a diff lost dirty code')
  c:input(' gd'); wait_for(function() return c:lua('return require("config.git_diff").status().visible') end, 'Diff did not reopen before terminal')
  c:input('<C-j>'); wait_for(function() return c:lua('return vim.bo.buftype') == 'terminal' end, 'Ctrl-J did not enter terminal from a Git diff')
  assert(not c:lua('return require("config.git_diff").status().visible'), 'Terminal switch left a stale HEAD diff')
  c:input('<C-j>'); wait_for(function() return c:lua('return vim.bo.buftype') == '' end, 'Ctrl-J did not restore code from terminal')
  same(c:lines(), edited, 'Terminal return after diff changed code')
  assert(c:lua('return require("config.terminal").sessions()[1].job')==session.job and c:lua('return require("config.terminal").sessions()[1].status')=='running', 'Git diff operations killed/replaced the terminal job')
  print('PASS Git diff: readonly HEAD/current unsaved buffer, left/right, toggle/manual close restoration, live tree/jobs, code-only session save')
  return before
end
local function finish(c)
  -- Real buffer edits continue through the existing delayed save machinery.
  c:lua([[require('config.autosave').setup({autosave={enabled=true,delay_ms=1000}}); vim.api.nvim_buf_set_lines(0,0,1,false,{'AUTOSAVED HEAD comparison'})]])
  local expected = c:lines(); pause(400); assert(fn.readfile(root..'/main 代码.txt')[1] ~= expected[1], 'Git integration bypassed autosave debounce')
  wait_for(function() return vim.deep_equal(fn.readfile(root..'/main 代码.txt'),expected) end, 'Edited Git buffer did not autosave')
  wait_for(function() return #hunks(c)>0 end, 'Autosave removed the still-uncommitted HEAD marks')
  c:lua([[require('config.autosave').setup({autosave={enabled=false}})]])
  local renamed = root .. '/renamed 代码.txt'
  local result = c:lua([[local from,to=...; local ok,err=require('config.explorer_files').rename_path(from,to); return {ok=ok,error=err}]], { root..'/main 代码.txt',renamed })
  assert(result.ok, 'Tree adapter rename failed with Git tracking: '..vim.inspect(result))
  same(c:lines(), expected, 'Tree rename lost Git buffer content')
  assert(same_path(c:lua('return vim.api.nvim_buf_get_name(0)'),renamed), 'Git rename did not preserve current named buffer')
  c:lua([[require('config.terminal').toggle(); vim.cmd.stopinsert(); require('config.terminal').toggle()]])
  assert(same_path(c:lua('return vim.api.nvim_buf_get_name(0)'),renamed),'Terminal returned to old path after tree rename')
  print('PASS Git integration: delayed autosave retains HEAD signs; tree rename and persistent terminal return preserve code')
end
local function run()
  fixture(); local original_index=index_hash(); local c=spawn(false)
  assert(c:lua([[return vim.fn.exists(':GitChanges')==2 and vim.fn.exists(':GitDiffToggle')==2]]), 'Git commands are not installed')
  local edited=signs(c); changes(c,edited); diff(c,edited)
  -- Reload the saved session in an independent owned process before rename.
  local restored=spawn(true)
  assert(restored:lua([[local wanted=...; local count,found=0,false; for _,w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do local b=vim.api.nvim_win_get_buf(w); if vim.wo[w].diff or vim.b[b].my_nvim_git_diff or vim.bo[b].buftype=='terminal' or vim.bo[b].filetype:match('^snacks_picker') then return false end; count=count+1; found=found or vim.fs.normalize(vim.api.nvim_buf_get_name(b)):lower()==vim.fs.normalize(wanted):lower() end; return found and count==1]], {root..'/main 代码.txt'}), 'Session did not restore the real single code window without HEAD/tree/terminal windows or diff flags')
  assert(not restored:lua('return require("config.git_diff").status().visible'), 'Restored project retained an owned diff')
  restored:shutdown(); finish(c)
  same(index_hash(), original_index, 'Read-only Git integration modified the fixture index')
  -- Only these explicit fixture commands may change the test repository index.
  c:open('untracked.txt'); wait_for(function() return #marks(c)>0 end,'Untracked additions disappeared before the explicit fixture commit')
  git({'add','--','untracked.txt'})
  git({'-c','user.name=Neovim integration test','-c','user.email=nvim-test@example.invalid','-c','commit.gpgsign=false','commit','--quiet','-m','commit new fixture files'})
  wait_for(function() return c:lua([[
    local ns=vim.api.nvim_get_namespaces()['my-nvim-git-newfiles']
    local fallback=ns and #vim.api.nvim_buf_get_extmarks(0,ns,0,-1,{details=true}) or 0
    local hunks=require('gitsigns').get_hunks(0)
    return fallback==0 and hunks~=nil and #hunks==0
  ]]) end,'External fixture commit did not clear fallback signs and attach native HEAD tracking',15000)
  print('PASS Git new files: staged-new/untracked additions; external commit hands signs back to native HEAD tracking')
end
vim.schedule(function()
  local ok,err=xpcall(run,debug.traceback)
  for _,c in ipairs(children) do pcall(c.shutdown,c); if ok and (not c.exited or c.exited.code~=0) then ok,err=false,'Owned Git UI did not exit cleanly' end end
  if ok then print('PASS all Git integration scenarios; fixtures: '..base); vim.cmd('qa!') else api.nvim_err_writeln(err); vim.cmd('cquit 1') end
end)