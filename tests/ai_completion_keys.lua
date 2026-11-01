-- nvim --headless -u ./init.lua -c "lua dofile('tests/ai_completion_keys.lua')"
-- Real embedded keyboard input, Blink menus/snippets and Minuet virtual text.
assert(vim.g.my_nvim_ready, 'Load the my-nvim configuration before this test')
vim.g.my_nvim_ai_test_library = true
local H = dofile(vim.fs.joinpath(vim.g.my_nvim_root, 'tests/ai_completion.lua'))
vim.g.my_nvim_ai_test_library = nil
local test
local function text(client) return table.concat(client:inspect().lines,'\n') end
local function menu(client)
  client:lua([[
    -- Keep selection from changing the buffer before the user actually accepts;
    -- this exercises the case where a real menu and real AI ghost coexist.
    require('blink.cmp.config').completion.list.selection.auto_insert=false
    require('blink.cmp').show({providers={'buffer'}})
  ]])
  H.wait(function() return client:lua("return require('blink.cmp').is_menu_visible()") end,'Real Blink menu did not open')
  local selected=client:lua("local c=require('blink.cmp'); local i=c.get_selected_item(); return i and (i.insertText or i.label) or vim.NIL")
  assert(type(selected)=='string','Blink did not select a real buffer candidate')
  return selected
end
local function completion_fixture(client,name)
  client:edit(name,{'ordinaryAlpha ordinaryBeta','ord TAIL'},{2,3})
end
local function run()
  test=H.environment('keys')
  local no_key=test:client({})
  assert(not no_key:status().enabled,'No-key keyboard baseline unexpectedly enabled AI')
  completion_fixture(no_key,'no-key-menu.txt')
  menu(no_key)
  no_key:input('<Tab>')
  H.pause(100)
  local no_key_view=no_key:inspect()
  assert(no_key_view.lines[2]:match('^ord%s+TAIL$'),'No-key Tab stopped using ordinary whitespace/snippet fallback')
  assert(not no_key_view.lines[2]:find('ordinary',1,true),'No-key Tab started accepting a Blink candidate')

  no_key:edit('no-key-snippet.txt',{' '},{1,0})
  no_key:lua("vim.snippet.expand('${1:FIRST} ${2:SECOND}$0')")
  H.wait(function() return no_key:lua('return vim.snippet.active({direction=1})') end,'Native snippet did not become active')
  local snippet_before=no_key:inspect()
  no_key:input('<Tab>')
  H.wait(function() return not vim.deep_equal(no_key:inspect().cursor,snippet_before.cursor) end,'No-key Tab did not advance the real snippet')
  assert(vim.deep_equal(no_key:inspect().lines,snippet_before.lines),'Snippet Tab inserted whitespace instead of advancing')
  no_key:lua('vim.snippet.stop()')

  no_key:edit('ctrl-l-baseline.txt',{'prefix TAIL'},{1,7})
  no_key:input('<C-l>'); H.pause(80)
  local baseline=no_key:inspect()
  assert(test:count()==0,'No-key keypresses sent an AI request')
  no_key:shutdown()
  print('PASS AI keys without credentials: real Blink menu does not change Tab, snippet forwarding and Ctrl-l fallback remain available')

  for _,key in ipairs({'<Tab>','<C-l>'}) do
    local client=test:client({env_key='ENV_FAKE_KEY'})
    client:edit('ai-accept-'..(key=='<Tab>' and 'tab' or 'ctrl-l')..'.txt',{'prefix TAIL'},{1,7})
    local candidate=key=='<Tab>' and 'AI_TAB_RESULT' or 'AI_CTRL_L_RESULT'
    H.trigger(test,client,candidate); client:ghost(candidate)
    assert(not client:lua("return require('blink.cmp').is_menu_visible()"),'AI-only accept fixture unexpectedly had an ordinary menu')
    client:input(key)
    H.wait(function() return text(client):find(candidate,1,true) ~= nil end,key..' did not accept actual AI virtual text')
    client:shutdown()
  end
  print('PASS AI keys: Tab without menu and Ctrl-l accept real Minuet ghost text through Blink textlock')

  for _,key in ipairs({'<Tab>','<C-y>'}) do
    local client=test:client({env_key='ENV_FAKE_KEY'})
    completion_fixture(client,'menu-priority-'..(key=='<Tab>' and 'tab' or 'ctrl-y')..'.txt')
    H.trigger(test,client,'AI_MUST_NOT_WIN'); client:ghost('AI_MUST_NOT_WIN')
    local ordinary=menu(client)
    assert(client:inspect().ghost:find('AI_MUST_NOT_WIN',1,true),'Menu-priority fixture lost the real coexisting AI ghost')
    client:input(key)
    H.wait(function() return client:inspect().lines[2]:find(ordinary,1,true) ~= nil end,key..' did not accept the ordinary Blink item')
    assert(not text(client):find('AI_MUST_NOT_WIN',1,true),key..' incorrectly preferred AI over the ordinary menu')
    client:shutdown()
  end
  print('PASS AI menu priority: real Tab/Ctrl-y select ordinary candidates while the Minuet ghost is visible')

  local fallback=test:client({env_key='ENV_FAKE_KEY'})
  fallback:edit('enabled-fallback.txt',{'prefix TAIL'},{1,7})
  fallback:input('<C-l>'); H.pause(80)
  local actual=fallback:inspect()
  assert(vim.deep_equal(actual.lines,baseline.lines) and actual.mode==baseline.mode,'Ctrl-l without AI changed its original fallback behavior')
  fallback:shutdown()

  for _,key in ipairs({'<Esc>','<CR>'}) do
    local client=test:client({env_key='ENV_FAKE_KEY'})
    client:edit('ordinary-'..(key=='<Esc>' and 'escape' or 'enter')..'.txt',{'prefix TAIL'},{1,7})
    H.trigger(test,client,'AI_DO_NOT_ACCEPT'); client:ghost('AI_DO_NOT_ACCEPT')
    client:input(key)
    if key=='<Esc>' then H.wait(function() return client:inspect().mode=='n' end,'Escape no longer exits insert mode')
    else H.wait(function() return #client:inspect().lines==2 end,'Enter no longer inserts a newline') end
    assert(not text(client):find('AI_DO_NOT_ACCEPT',1,true),key..' accepted AI unexpectedly')
    assert(not client:status().visible,'Escape/Enter left a stale AI ghost')
    client:shutdown()
  end
  print('PASS AI ordinary keys: no-suggestion Ctrl-l fallback, Escape exit and Enter newline remain unchanged')

  local cmdline=test:client({env_key='ENV_FAKE_KEY'})
  cmdline:edit('cmdline.txt',{'fixture'},{1,0},nil,false)
  local root=vim.fs.joinpath(test.base,'cmdline-directories')
  vim.fn.mkdir(root..'/apples','p'); vim.fn.mkdir(root..'/apricots','p')
  cmdline:lua([[
    vim.keymap.set('c','<F12>',function() vim.g.ai_test_cmdline=vim.fn.getcmdline(); return '' end,{expr=true})
  ]])
  local before=test:count()
  cmdline:input(':edit '..vim.fn.fnameescape(root..'/a')..'<Tab><F12><Esc>')
  H.wait(function() return cmdline:lua('return vim.g.ai_test_cmdline~=nil') end,'Native command-line completion did not run')
  local completed=cmdline:lua('return vim.g.ai_test_cmdline'):gsub('\\','/')
  assert(completed:match('/ap$'),'AI keymaps changed native command-line Tab common-prefix completion')
  assert(test:count()==before,'Command-line completion triggered an AI request')
  cmdline:shutdown()
  print('PASS AI cmdline: native Tab common-prefix completion stays separate and sends no API request')
end
vim.schedule(function()
  local ok,err=xpcall(run,debug.traceback)
  if test then test:cleanup() end
  if not ok then vim.api.nvim_err_writeln(err); vim.cmd('cquit 1') else print('PASS all AI keyboard integration scenarios'); vim.cmd('qa!') end
end)
