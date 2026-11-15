-- Dependency-free CC:Tweaked harness. Run from repository root with Lua 5.3+.
local hostLoad, hostDo = loadfile, dofile
local total = 0
local function clone(v)
  if type(v) ~= 'table' then return v end
  local out = {} for k,x in pairs(v) do out[k] = clone(x) end return out
end
local function harness(opts)
  opts = opts or {}
  local h = {time=0, utc=1000000, files={}, packets={}, lines={}, stops=0,
    active=opts.active~=false, rate=1, actual=1, coolant=.8, present=true, damage=0, timers=0}
  local tokens, tokenID = {}, 0
  local env = setmetatable({}, {__index=_G})
  env.os = {clock=function() return h.time end, epoch=function() return h.utc end,
    getComputerID=function() return 17 end,
    startTimer=function() h.timers=h.timers+1 return h.timers end,
    pullEventRaw=function() return coroutine.yield('event') end,
    pullEvent=function() return coroutine.yield('event') end}
  env.print=function(s) h.lines[#h.lines+1]=tostring(s) end
  env.colors={black=1,white=2,red=3,cyan=4,orange=5,lime=6,yellow=7,lightGray=8}
  env.keys={s=31,u=22,r=19,right=205}
  env.term={setBackgroundColor=function() end,setTextColor=function() end,
    clear=function() if h.breakUI then error('monitor failure') end end,
    setCursorPos=function() end,getSize=function() return 80,32 end,
    write=function(s) h.lines[#h.lines+1]=s end}
  env.settings={get=function(k) if k=='reator.source' then return opts.source end end}
  env.shell={getRunningProgram=function() return 'minecraft/mekanism/reator_seguro.lua' end}
  env.textutils={serializeJSON=function(t)
    tokenID=tokenID+1 local token='json-'..tokenID tokens[token]=clone(t) return token
  end,unserializeJSON=function(raw) return clone(tokens[raw]) end}
  env.fs={getDir=function(p) return p:match('^(.*)/') or '' end,
    combine=function(a,b) return a..'/'..b end,
    exists=function(p) return h.files[p]~=nil end,
    getSize=function(p) return #(h.files[p] or '') end,
    delete=function(p) if h.failDelete then error('cannot delete') end h.files[p]=nil end,
    move=function(a,b) if h.failMove then error('cannot rename') end h.files[b]=h.files[a] h.files[a]=nil end,
    open=function(p,m)
      if m=='r' and not h.files[p] then return nil end
      if m~='r' and h.failDisk then return nil end
      local buffer=m=='a' and (h.files[p] or '') or ''
      return {write=function(s) buffer=buffer..s end,writeLine=function(s) buffer=buffer..s..'\n' end,
        close=function() if m~='r' then h.files[p]=buffer end end,
        readAll=function() return h.files[p] end}
    end}
  local p = {getStatus=function() return h.active end,
    scram=function() h.stops=h.stops+1 if not h.failScram then h.active=false end end,
    getBurnRate=function() return h.rate end,getActualBurnRate=function() return h.actual end,
    getTemperature=function() return (h.temp or 100)+273.15 end,
    getDamagePercent=function() return h.damage end,
    getCoolantFilledPercentage=function() if h.failRead then error('disconnected') end return h.coolant end,
    getHeatedCoolantFilledPercentage=function() return .1 end,getWasteFilledPercentage=function() return .1 end,
    getFuelFilledPercentage=function() return .8 end,getHeatingRate=function()
      if h.readDelay then h.time=h.time+h.readDelay h.utc=h.utc+h.readDelay*1000 end
      if h.changeDuringRead then h.rate=h.rate+1 end
      return 100
    end,
    getMaxBurnRate=function() return 100 end,getCoolant=function() return {name='mekanism:sodium',amount=80000} end}
  for _, k in ipairs({'getCoolantCapacity','getHeatedCoolantCapacity','getWasteCapacity','getFuelCapacity',
    'getFuelAssemblies','getFuelSurfaceArea','getHeatCapacity'}) do p[k]=function() return h.capacity or 100000 end end
  local modem={transmit=function(_,_,packet)
    if h.breakModem then error('modem broken') end
    h.packets[#h.packets+1]=clone(packet)
  end,open=function() end}
  env.peripheral={getNames=function() return h.present and {'reactor_0'} or {} end,
    wrap=function(name) if h.present and name=='reactor_0' then return p end end,
    isPresent=function(name) return h.present and name=='reactor_0' end,
    find=function(kind) if kind=='modem' then return modem end end}
  env.dofile=function(path)
    if h.missingCore then error('module missing') end
    return assert(hostLoad(path,'t',env))()
  end
  function h:boot(panel)
    self.co=coroutine.create(assert(hostLoad('minecraft/mekanism/'..(panel and 'painel_reator.lua' or 'reator_seguro.lua'),'t',env)))
    local ok,why=coroutine.resume(self.co)
    assert(ok,why)
  end
  function h:event(name,...)
    local ok,why=coroutine.resume(self.co,name,...)
    assert(ok,why)
  end
  function h:tick(n)
    for _=1,n or 1 do
      self.time,self.utc=self.time+.25,self.utc+250
      self:event('timer',self.timers)
    end
  end
  function h:release() self:event('key',env.keys.u) end
  function h:last() return self.packets[#self.packets] end
  function h:record(path,obj) self.files[path]=env.textutils.serializeJSON(obj) end
  function h:read(path) return env.textutils.unserializeJSON(self.files[path]) end
  return h
end
local function test(name,fn)
  local ok,err=pcall(fn)
  assert(ok,name..': '..tostring(err))
  total=total+1 print('OK '..name)
end
test('startup SCRAM, manual release and automatic decimal-rate testing',function()
  local h=harness() h:boot()
  assert(not h.active and h.stops>=1 and h:read('/reator_scram.json'))
  h:release() h.active=true h.rate,h.actual=3.713,3.713
  h:tick(8)
  assert(h:last().state=='ESTABILIZANDO' and h:last().trial.target==3.713)
end)
test('UI and modem exceptions cannot stop control loop',function()
  local h=harness() h:boot() h:release() h.active=true
  h.breakUI,h.breakModem=true,true h:tick(8)
  h.damage=1 h:tick()
  assert(not h.active and h.stops>=2)
end)
test('read failures SCRAM and cannot use previous good snapshot',function()
  local h=harness() h:boot() h:release() h.active=true h:tick(8)
  h.failRead=true h:tick(8)
  assert(not h.active and h:last().state=='BLOQUEADO' and h:last().data==nil)
end)
test('NaN prevents validation and triggers SCRAM',function()
  local h=harness() h:boot() h:release() h.active=true h.coolant=0/0 h:tick(8)
  assert(not h.active and h:last().state=='BLOQUEADO')
end)
test('CTRL+T SCRAM remains enforced and is not confirmed falsely',function()
  local h=harness() h:boot() h:release() h.active=true h.failScram=true
  h:event('terminate') h:tick(8)
  assert(h.active and h:last().scramConfirmed==false)
  h.failScram=false h:tick(8)
  assert(not h.active and h:last().scramConfirmed==true)
end)
test('disconnect latches and reconnect retries SCRAM on same reactor',function()
  local h=harness() h:boot() h:release() h.active=true h:tick(4)
  h.present=false h:event('peripheral_detach','reactor_0') h:tick(8)
  assert(h:last().scramConfirmed==false)
  h.present=true h:tick(8)
  assert(not h.active and h:last().scramConfirmed==true)
end)
test('suspension gap causes SCRAM after resumption',function()
  local h=harness() h:boot() h:release() h.active=true h:tick(4)
  h.utc=h.utc+5000 h:tick(8)
  assert(not h.active and h:last().reason=='INTERVALO SEM LEITURAS CONFIAVEIS')
end)
test('corrupt history cannot silently unlock',function()
  local h=harness() h.files['/reator_auto_v2.json']='bad-json' h:boot() h:release()
  h:tick(8) assert(h:last().state=='BLOQUEADO')
end)
test('incomplete atomic transaction requires repair',function()
  local h=harness() h.files['/reator_auto_v2.json.pending']='pending' h:boot() h:release()
  h:tick(8) assert(h:last().state=='BLOQUEADO')
end)
test('storage failure prevents manual release',function()
  local h=harness() h:boot() h.failDisk=true h:release() h:tick(8)
  assert(h:last().state=='BLOQUEADO' and not h.active)
end)
test('approval is written only after complete stable measurement',function()
  local h=harness() h:boot() h:release() h.active=true
  h:tick(3130)
  assert(h:last().state=='APROVADO')
  local db=h:read('/reator_auto_v2.json')
  assert(db.schema==2 and next(db.approvals))
  assert(h.files['/reator_testes_v2.jsonl'])
  h.rate,h.actual=2.5,2.5 h:tick(8)
  assert(h:last().state=='ESTABILIZANDO' and h:last().trial.target==2.5)
end)
test('missing core still stops reactor before entering recovery loop',function()
  local h=harness() h.missingCore=true h:boot()
  assert(not h.active and h.stops>=1)
  assert(h:read('/reator_scram.json').reason:find('ERRO INTERNO'))
end)
test('slow or incoherent snapshots are rejected and stopped',function()
  for _, kind in ipairs({'delay','change'}) do
    local h=harness() h:boot() h:release() h.active=true h:tick(4)
    if kind=='delay' then h.readDelay=3 else h.changeDuringRead=true end
    h:tick(8)
    assert(not h.active and h:last().state=='BLOQUEADO')
  end
end)
test('observed capacity change invalidates an active evaluation',function()
  local h=harness() h:boot() h:release() h.active=true h:tick(24)
  h.capacity=200000 h:tick(24)
  assert(not h.active and h:last().reason=='CONFIGURACAO DO REATOR MUDOU')
end)
test('clean restart keeps references but requires SCRAM release and revalidation',function()
  local h=harness() h:boot() h:release() h.active=true h:tick(3130)
  assert(next(h:read('/reator_auto_v2.json').approvals))
  h:boot()
  assert(not h.active)
  h:release() h.active=true h:tick(8)
  assert(h:last().state=='REVALIDANDO')
end)
test('fault revokes persistent references before a subsequent restart',function()
  local h=harness() h:boot() h:release() h.active=true h:tick(3130)
  h.damage=1 h:tick(24)
  assert(next(h:read('/reator_auto_v2.json').approvals)==nil)
  h.damage=0 h:boot() h:release() h.active=true h:tick(8)
  assert(h:last().state=='ESTABILIZANDO')
end)
test('approval storage failure immediately latches SCRAM',function()
  local h=harness() h:boot() h:release() h.active=true h:tick(3000)
  h.failDisk=true h:tick(140)
  assert(not h.active and h:last().reason=='FALHA AO SALVAR TESTE')
end)
test('unsafe but valid readings remain visible after SCRAM',function()
  local h=harness() h:boot() h:release() h.active=true h:tick(8)
  h.temp=500 h:tick(8)
  assert(not h.active and h:last().reason=='TEMPERATURA ALTA')
  assert(h:last().data.tempC==500 and h:last().data.active==false)
  h.coolant=.1 h:tick(8)
  assert(h:last().data.coolant==.1 and h:last().state=='BLOQUEADO')
end)
test('display requires controller selection and rejects malformed or stale packets',function()
  local h=harness({source=17}) h:boot(true)
  local packet={kind='mek_fission_telemetry_v2',source=17,mode='auto',session='1',sequence=1,
    utc=h.utc,state='MEDINDO',duration=600,stabilize=120,trial={target=3,elapsed=2,settle=120}}
  h:event('modem_message','left',42,42,clone(packet)) h:tick(2)
  assert(table.concat(h.lines,' '):find('MEDINDO'))
  local before=#h.lines
  packet.sequence=2 packet.state='BAD_ACCEPTED' packet.source=99
  h:event('modem_message','left',42,42,clone(packet)) h:tick(2)
  packet.source=17 packet.trial.elapsed='bad'
  h:event('modem_message','left',42,42,clone(packet)) h:tick(2)
  packet.trial.elapsed=2 packet.utc=h.utc-9000
  h:event('modem_message','left',42,42,clone(packet)) h:tick(2)
  assert(not table.concat(h.lines,' ',before):find('BAD_ACCEPTED'))
  h:tick(20)
  assert(table.concat(h.lines,' '):find('SEM TELEMETRIA ATUAL'))
end)
print(total..' runtime scenarios passed')
