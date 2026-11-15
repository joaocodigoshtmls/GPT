-- Passive inventory and explicit export: no real network or peripherals.
local total=0
local function test(name,fn)
  local ok,err=pcall(fn) assert(ok,name..': '..tostring(err))
  total=total+1 print('OK '..name)
end
local function env()
  local h={files={},lines={},reads=0,posts=0}
  local e=setmetatable({}, {__index=_G})
  e.print=function(s) h.lines[#h.lines+1]=s end
  e._HOST='ComputerCraft test'
  e.os={getComputerID=function() return 17 end,epoch=function() return 1000 end}
  e.settings={get=function() return 'reactor_0' end}
  e.textutils={serializeJSON=function(v) return tostring(v) end,urlEncode=function(v) return v end}
  e.fs={exists=function(p) return h.files[p]~=nil end,isDir=function() return false end,
    getName=function(p) return p:match('[^/]+$') end,
    open=function(p,m)
      local body=''
      return {readAll=function() return h.files[p] end,write=function(s) body=body..s end,
        close=function() if m=='w' then h.files[p]=body end end}
    end}
  function h:run(name,arg)
    assert(loadfile('minecraft/mekanism/'..name..'.lua','t',e))(arg)
  end
  return h,e
end
test('inventory calls getters only and records absent methods',function()
  local h,e=env()
  local reactor={getBurnRate=function() h.reads=h.reads+1 return 1 end,
    scram=function() error('must not SCRAM') end,
    activate=function() error('must not activate') end,
    setBurnRate=function() error('must not set burn') end}
  e.peripheral={getNames=function() return {'reactor_0'} end,
    wrap=function() return reactor end,getMethods=function() return {'scram','getBurnRate'} end}
  h:run('verificar_reator')
  assert(h.reads==1 and h.files['/verificacao_reator.txt']:find('METODO AUSENTE'))
end)
test('upload preserves HTTP failure status and response details',function()
  local h,e=env() h.files['/relatorio_reator.txt']='report'
  e.http={post=function()
    h.posts=h.posts+1
    return nil,'Could not connect',{getResponseCode=function() return 403,'Forbidden' end,
      readAll=function() return 'blocked' end,close=function() h.closed=true end}
  end}
  h:run('enviar_relatorio')
  local log=h.files['/envio_reator.txt']
  assert(h.posts==1 and h.closed and log:find('403') and log:find('Could not connect') and log:find('blocked'))
  assert(h.files['/relatorio_reator.txt']=='report')
end)
test('API rejection with HTTP success is not presented as upload success',function()
  local h,e=env() h.files['/relatorio_reator.txt']='report'
  e.http={post=function() return {getResponseCode=function() return 200,'OK' end,
    readAll=function() return 'Bad API request' end,close=function() end} end}
  h:run('enviar_relatorio')
  assert(h.files['/envio_reator.txt']:find('ENVIO NAO CONFIRMADO'))
end)
test('valid Pastebin URL confirms explicit upload',function()
  local h,e=env() h.files['/relatorio_reator.txt']='report'
  e.http={post=function() return {getResponseCode=function() return 200,'OK' end,
    readAll=function() return 'https://pastebin.com/Ab123' end,close=function() end} end}
  h:run('enviar_relatorio')
  assert(h.files['/envio_reator.txt']:find('Envio confirmado'))
end)
test('arbitrary local files cannot be uploaded by this tool',function()
  local h=env()
  assert(not pcall(function() h:run('enviar_relatorio','/startup.lua') end))
  assert(h.posts==0)
end)
print(total..' tools scenarios passed')
