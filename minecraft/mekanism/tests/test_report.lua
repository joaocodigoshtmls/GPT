local path='minecraft/mekanism/relatorio_reator.lua'
local function run(events, options)
  options=options or {}
  local h={time=0,files=options.files or {},records={},prints={},actions=0}
  local env=setmetatable({}, {__index=_G})
  env._HOST='test host'
  env.settings={get=function() return options.source end}
  env.os={clock=function() return h.time end, epoch=function() return 1000000+h.time*1000 end,
    getComputerID=function() return 3 end,startTimer=function() return 1 end,
    pullEventRaw=function()
      local e=table.remove(events,1)
      if not e then h.time=60 return 'timer',1 end
      h.time=e.at or h.time+.25
      return table.unpack(e)
    end}
  env.print=function(line) h.prints[#h.prints+1]=line end
  local p={open=function(c) assert(c==42) end,transmit=function() error('must not transmit') end,
    scram=function() error('must not control reactor') end,activate=function() error('must not activate') end}
  env.peripheral={getNames=function() return options.noModem and {} or {'left'} end,
    wrap=function() return p end}
  env.textutils={serializeJSON=function(t)
    h.records[#h.records+1]=t
    return 'JSON '..#h.records
  end}
  env.fs={exists=function(p) return h.files[p]~=nil end,
    delete=function(p) h.files[p]=nil end,
    move=function(a,b) assert(h.files[a]) h.files[b]=h.files[a] h.files[a]=nil end,
    open=function(p,m)
      assert(m=='w')
      local text=''
      return {write=function(s) text=text..s end,close=function() h.files[p]=text end}
    end}
  assert(loadfile(path,'t',env))()
  return h
end
local count=0
local function test(name,fn)
  local ok,err=pcall(fn) assert(ok,name..': '..tostring(err))
  count=count+1 print('OK '..name)
end
local function packet(kind,source)
  return {kind=kind or 'mek_fission_telemetry_v2',source=source or 17,state='MEDINDO',
    data={burn=1,actual=1,tempC=100,coolant=.8,active=true},trial={phase='MEDINDO',elapsed=10}}
end
local function event(p,at) return {'modem_message','left',42,42,p,2,at=at} end
test('V1 and V2 diagnostics without transmitting or reactor commands',function()
  local h=run({event(packet('mek_fission_telemetry_v1'),1),event(packet(),2)})
  assert(#h.records==3 and h.records[2].kind=='mek_fission_telemetry_v1')
  assert(h.records[3].data.burn==1 and h.records[3].trial.elapsed==10)
  assert(h.files['/relatorio_reator.txt']:find('IDs observados: 17'))
end)
test('missing modem still produces an explicit report',function()
  local h=run({}, {noModem=true})
  assert(h.files['/relatorio_reator.txt']:find('NENHUM MODEM'))
end)
test('no packets does not imply reactor is off',function()
  local h=run({})
  assert(h.files['/relatorio_reator.txt']:find('NAO E EVIDENCIA DE REATOR DESLIGADO'))
end)
test('filter retains observed IDs to diagnose wrong selection',function()
  local h=run({event(packet(nil,99),1)},{source=17})
  assert(h.records[1].selected==0 and h.records[1].otherSource==1)
  assert(h.files['/relatorio_reator.txt']:find('IDs observados: 99'))
end)
test('state changes kept between regular one-second samples',function()
  local a,b,c=packet(),packet(),packet()
  b.state='BLOQUEADO' b.reason='FALHA DE LEITURA'
  local h=run({event(a,1),event(c,1.25),event(b,1.5)})
  assert(#h.records==3 and h.records[3].reason=='FALHA DE LEITURA')
end)
test('malformed and nonfinite telemetry sanitized without serializing arbitrary data',function()
  local a=packet()
  a.data.tempC=0/0 a.data.secret='not exported' a.secret='not exported' a.loop=a
  local h=run({event(false,1),event(a,2)})
  assert(h.records[1].malformed==1 and h.records[2].data.tempC=='INVALIDO (number)')
  assert(h.records[2].data.secret==nil and h.records[2].secret==nil and h.records[2].loop==nil)
end)
test('previous diagnostic report preserved as backup',function()
  local h=run({}, {files={['/relatorio_reator.txt']='previous report'}})
  assert(h.files['/relatorio_reator.txt.anterior']=='previous report')
end)
print(count..' diagnostics scenarios passed')
