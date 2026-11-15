-- Installer simulation: no real network, peripherals, startup mutation or execution.
local path='minecraft/mekanism/fission/install.lua'
local SHA=string.rep('a',40)
local count=0
local function test(name,fn)
  local ok,err=pcall(fn)
  assert(ok,name..': '..tostring(err))
  count=count+1 print('OK '..name)
end
local function harness(options)
  options=options or {}
  local h={files={['/startup.lua']='original startup'},dirs={['/']=true},urls={},printed={},closed=0}
  for name,value in pairs(options.files or {}) do h.files[name]=value end
  for _,name in ipairs(options.dirs or {}) do h.dirs[name]=true end
  local env=setmetatable({}, {__index=_G})
  env.print=function(s) h.printed[#h.printed+1]=tostring(s) end
  env.write=function() end
  env.read=function() error('unexpected prompt') end
  env.os={getComputerID=function() return 7 end}
  env.shell={resolve=function(p) return p:sub(1,1)=='/' and p or '/'..p end,
    run=function() error('installer must not run programs') end}
  env.peripheral={find=function() error('installer must not control peripherals') end}
  env.textutils={unserializeJSON=function(raw)
    if raw=='REF' then return {object={type='commit',sha=SHA}} end
  end}
  env.fs={exists=function(p) return h.files[p]~=nil or h.dirs[p] end,
    combine=function(a,b) return a..'/'..b end,
    makeDir=function(p) assert(not h.files[p]) h.dirs[p]=true end,
    delete=function(p)
      h.files[p],h.dirs[p]=nil,nil
      for k in pairs(h.files) do if k:sub(1,#p+1)==p..'/' then h.files[k]=nil end end
      for k in pairs(h.dirs) do if k:sub(1,#p+1)==p..'/' then h.dirs[k]=nil end end
    end,
    move=function(a,b)
      if options.failMove then error('cannot rename') end
      assert(h.dirs[a] and not h.dirs[b] and not h.files[b])
      h.dirs[a],h.dirs[b]=nil,true
      local moved={}
      for k,v in pairs(h.files) do
        if k:sub(1,#a+1)==a..'/' then moved[b..k:sub(#a+1)]=v h.files[k]=nil end
      end
      for k,v in pairs(moved) do h.files[k]=v end
    end,
    open=function(p,m)
      assert(m=='w')
      if options.failDisk then return nil end
      local body=''
      return {write=function(s) body=body..s end,close=function() h.files[p]=body end}
    end}
  env.http={get=function(url)
    h.urls[#h.urls+1]=url
    local name=url:match('[^/]+$')
    if name==options.failFile then
      return nil,'network refused',{close=function() h.closed=h.closed+1 end}
    end
    local raw
    if url:find('api.github.com',1,true) then raw='REF'
    elseif name=='config.lua' then raw='return { CONTROLLER_ID = nil, PANEL_ID = nil }'
    elseif name==options.invalidFile then raw='local invalid = '
    elseif name:sub(-4)=='.lua' then raw='error("downloaded code must never run during installation")'
    else raw='attribution and license' end
    return {getResponseCode=function() return 200 end,
      readAll=function() return raw end,close=function() h.closed=h.closed+1 end}
  end}
  function h:run(role,id,dest,commit)
    return pcall(assert(loadfile(path,'t',env)),role or 'reactor',id or '12',dest,commit)
  end
  return h
end
test('complete package is pinned and published only after successful checks',function()
  local h=harness()
  local ok,result=h:run()
  assert(ok,result)
  assert(result=='/fission_v3' and h.dirs['/fission_v3'])
  assert(not h.dirs['/fission_v3.installing'])
  assert(h.files['/fission_v3/config.lua']:find('PANEL_ID = 12',1,true))
  assert(h.files['/fission_v3/config.lua']:find('CONTROLLER_ID = nil',1,true))
  assert(h.files['/fission_v3/INSTALLED.txt']:find(SHA,1,true))
  assert(h.files['/startup.lua']=='original startup')
  assert(#h.urls==8 and h.closed==8)
  for i=2,#h.urls do assert(h.urls[i]:find('/'..SHA..'/',1,true)) end
end)
test('panel peer selection and supplied immutable commit skip branch lookup',function()
  local h=harness()
  local ok,err=h:run('painel','0','/display',SHA)
  assert(ok,err)
  assert(#h.urls==7)
  assert(h.files['/display/config.lua']:find('CONTROLLER_ID = 0',1,true))
  assert(h.files['/display/config.lua']:find('PANEL_ID = nil',1,true))
end)
test('existing destination is never overwritten',function()
  local h=harness({dirs={'/fission_v3'},files={['/fission_v3/config.lua']='existing'}})
  local ok=h:run()
  assert(not ok and #h.urls==0)
  assert(h.files['/fission_v3/config.lua']=='existing')
  assert(h.files['/startup.lua']=='original startup')
end)
test('preexisting pending installation is preserved for review',function()
  local h=harness({dirs={'/fission_v3.installing'},files={['/fission_v3.installing/evidence']='keep'}})
  local ok=h:run()
  assert(not ok and #h.urls==0)
  assert(h.files['/fission_v3.installing/evidence']=='keep')
end)
test('HTTP failure rolls back only this incomplete staging directory',function()
  local h=harness({failFile='functions.lua'})
  local ok,err=h:run()
  assert(not ok and tostring(err):find('network refused',1,true))
  assert(not h.dirs['/fission_v3'] and not h.dirs['/fission_v3.installing'])
  assert(h.files['/startup.lua']=='original startup')
  assert(h.closed==#h.urls)
end)
test('invalid Lua cannot be installed or executed',function()
  local h=harness({invalidFile='reactor.lua'})
  local ok,err=h:run()
  assert(not ok and tostring(err):find('Sintaxe invalida',1,true))
  assert(not h.dirs['/fission_v3'] and not h.dirs['/fission_v3.installing'])
end)
test('failed final rename leaves no apparently complete target',function()
  local h=harness({failMove=true})
  local ok=h:run()
  assert(not ok and not h.dirs['/fission_v3'] and not h.dirs['/fission_v3.installing'])
  assert(h.files['/startup.lua']=='original startup')
end)
test('invalid peer ID prevents every network or installation action',function()
  local h=harness()
  local ok=h:run('reactor','not an ID')
  assert(not ok and #h.urls==0 and not h.dirs['/fission_v3.installing'])
end)
print(count..' installer scenarios passed')
