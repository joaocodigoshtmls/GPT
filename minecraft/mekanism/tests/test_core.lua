local Core = dofile("minecraft/mekanism/reator_core.lua")
local passed = 0
local function test(name, fn)
  local ok, why = pcall(fn)
  assert(ok, name .. ': ' .. tostring(why))
  passed = passed+1
  print('OK ' .. name)
end
local function data(rate)
  return {active=true, tempC=100, coolant=.8, heated=.1, waste=.1, fuel=.8,
    damage=0, burn=rate or 1, actual=rate or 1, maxBurn=100, heating=100, signature='reactor-A'}
end
local function approval(d, finished)
  return {phase='APROVADO',policy=Core.policy,signature=d.signature,target=d.burn,
    finished=finished or 1000000,duration=600,elapsed=600,sampleCount=601,
    min={tempC=100,coolant=.8,heated=.1,waste=.1,fuel=.8},
    max={tempC=100,coolant=.8,heated=.1,waste=.1,fuel=.8},
    slopes={tempC=0,coolant=0,heated=0,waste=0,fuel=0}}
end
local function run(e, d, first, last, change)
  for i=first*4,last*4 do
    local t=i/4
    if change then change(d,t) end
    e:step(d,t,1000000+t*1000)
    if e.lock then return end
  end
end
test('arbitrary decimal rate detected and fully approved',function()
  local e,d=Core.new(),data(3.713)
  run(e,d,0,779)
  assert(e.phase=='MEDINDO' and not e.result)
  run(e,d,780,781)
  assert(e.phase=='APROVADO' and e.result.target==3.713 and e.result.elapsed==600)
  assert(e.result.minCoolant==.8 and e.result.slopes.tempC==0)
end)
test('rate change cancels measurement and restarts automatically',function()
  local e,d=Core.new(),data(.5)
  run(e,d,0,300)
  d.burn,d.actual=12.34,12.34
  run(e,d,301,302)
  assert(not e.lock and e.target==12.34 and e.trial.elapsed==0)
  assert(e.result.reason=='TAXA ALTERADA')
  run(e,d,303,1082)
  assert(e.phase=='APROVADO' and e.trial.target==12.34)
end)
test('approval of one rate does not approve lower or higher untested rates',function()
  local e,d=Core.new(),data(5)
  run(e,d,0,781)
  d.burn,d.actual=4,4
  run(e,d,782,962)
  assert(not e.cached and e.phase=='MEDINDO')
end)
test('all recent exact rates cached, with fresh stabilization',function()
  local d=data(2)
  local a=approval(d)
  local e=Core.new({[Core.key(2,d.signature)]=a})
  run(e,d,0,10)
  assert(e.phase=='REVALIDANDO')
  run(e,d,11,181)
  assert(e.phase=='APROVADO' and e.cached==a and not e.result)
end)
test('expired, foreign and old-policy approvals ignored',function()
  for _, kind in ipairs({'expired','foreign','policy','nan','future','short'}) do
    local d=data(1)
    local a=approval(d)
    if kind=='expired' then a.finished=-Core.cfg.approvalTTL end
    if kind=='foreign' then a.signature='other' end
    if kind=='policy' then a.policy='old' end
    if kind=='nan' then a.target=0/0 end
    if kind=='future' then a.finished=90000000 end
    if kind=='short' then a.duration=300 end
    local e=Core.new({[Core.key(1,d.signature)]=a})
    run(e,d,0,1)
    assert(not e.cached,kind)
  end
end)
test('approval expiry during operation triggers complete retest',function()
  local d=data(1)
  local a=approval(d,1000000-Core.cfg.approvalTTL+190000)
  local e=Core.new({[Core.key(1,d.signature)]=a})
  run(e,d,0,181)
  assert(e.phase=='APROVADO')
  run(e,d,182,192)
  assert(e.phase=='ESTABILIZANDO' and not e.cached)
end)
test('actual burn mismatch never passes',function()
  local e,d=Core.new(),data(10)
  d.actual=1
  run(e,d,0,10)
  assert(e.lock.reason=='QUEIMA REAL DIFERENTE DA CONFIGURADA')
  assert(e.phase=='BLOQUEADO')
end)
test('transient actual mismatch interrupts measuring immediately',function()
  local e,d=Core.new(),data(1)
  run(e,d,0,200)
  d.actual=.9
  run(e,d,201,201)
  assert(e.lock and e.trial.phase=='INTERROMPIDO')
end)
test('short gaps and invalid clock never count toward approval',function()
  for _, kind in ipairs({'game','wall','reverse'}) do
    local e,d=Core.new(),data()
    e:step(d,0,1000000)
    if kind=='game' then e:step(d,3,1000250)
    elseif kind=='wall' then e:step(d,.25,1003000)
    else e:step(d,-.25,999750) end
    assert(e.lock and e.lock.reason=='INTERVALO SEM LEITURAS CONFIAVEIS')
  end
end)
test('NaN infinity missing data and out-of-range values lock',function()
  for _, field in ipairs({'tempC','burn','fuel','damage','maxBurn'}) do
    for _, value in ipairs({0/0,math.huge,-math.huge}) do
      local e,d=Core.new(),data()
      d[field]=value
      e:step(d,0,1000000)
      assert(e.lock,field)
    end
    local e,d=Core.new(),data()
    d[field]=nil
    e:step(d,0,1000000)
    assert(e.lock)
  end
  for _, k in ipairs({'coolant','heated','waste','fuel'}) do
    local e,d=Core.new(),data()
    d[k]=1.01
    e:step(d,0,1000000)
    assert(e.lock)
  end
end)
test('all absolute protection limits and inadequate start margins',function()
  for _, pair in ipairs({{'damage',.01},{'tempC',450},{'coolant',.2},{'heated',.85},
    {'waste',.75},{'fuel',.05},{'coolant',.49},{'heated',.51},{'waste',.51},{'fuel',.24}}) do
    local e,d=Core.new(),data()
    d[pair[1]]=pair[2]
    e:step(d,0,1000000)
    assert(e.lock,pair[1])
  end
end)
test('reactor configuration change trips instead of reusing old data',function()
  local e,d=Core.new(),data()
  run(e,d,0,10)
  d.signature='new-capacity'
  run(e,d,11,11)
  assert(e.lock.reason=='CONFIGURACAO DO REATOR MUDOU')
end)
test('slow coolant depletion trips even with stable temperature',function()
  local e,d=Core.new(),data()
  run(e,d,0,200,function(s,t) s.coolant=.8-t*.00001 end)
  assert(e.lock and e.lock.reason=='RESERVA DE REFRIGERANTE DIMINUINDO')
end)
test('heated coolant and waste accumulation independently trip',function()
  for _, key in ipairs({'heated','waste'}) do
    local e,d=Core.new(),data()
    run(e,d,0,200,function(s,t) s[key]=.1+t*.00001 end)
    assert(e.lock,key)
  end
end)
test('fast temperature rise predicts limit before threshold',function()
  local e,d=Core.new(),data()
  run(e,d,0,100,function(s,t) s.tempC=100+t*10 end)
  assert(e.lock and e.lock.reason=='LIMITE PREVISTO: tempC' and d.tempC<450)
end)
test('small continuous drift cannot pass using large tank buffer',function()
  local e,d=Core.new(),data()
  run(e,d,0,2000,function(s,t) s.coolant=.8-t*.0000009 end)
  assert(e.lock and e.phase~='APROVADO')
end)
test('finite fuel buffer is not approved as sustainable supply',function()
  local e,d=Core.new(),data()
  run(e,d,0,2000,function(s,t) s.fuel=.8-t*.00001 end)
  assert(e.lock and not e.approvals[Core.key(1,d.signature)])
end)
test('fuel starvation after approval revokes every reference',function()
  local e,d=Core.new(),data()
  run(e,d,0,781)
  run(e,d,782,1000,function(s,t) s.fuel=.8-(t-782)*.00001 end)
  assert(e.lock and next(e.approvals)==nil)
end)
test('normal stop does not count idle seconds and resumes a fresh test',function()
  local e,d=Core.new(),data()
  run(e,d,0,300)
  d.active=false
  run(e,d,301,500)
  assert(not e.lock and e.phase=='AGUARDANDO')
  d.active=true
  run(e,d,501,502)
  assert(e.trial.elapsed==0)
end)
test('bounded windows do not grow during extended supervision',function()
  local e,d=Core.new(),data()
  run(e,d,0,4000)
  assert(not e.lock and e.phase=='APROVADO' and #e.samples<=725 and #e.guards<=65)
end)
test('changing targets repeatedly cannot erase depletion protection',function()
  local e,d=Core.new(),data()
  run(e,d,0,200,function(s,t)
    s.burn=1+math.floor(t)%2 s.actual=s.burn s.coolant=.8-t*.00001
  end)
  assert(e.lock and e.lock.reason=='RESERVA DE REFRIGERANTE DIMINUINDO')
end)
test('corrupt persisted evidence cannot become a cached approval',function()
  for _, kind in ipairs({'samples','stats','slope','elapsed'}) do
    local d=data()
    local a=approval(d)
    if kind=='samples' then a.sampleCount=3
    elseif kind=='stats' then a.min.coolant=nil
    elseif kind=='slope' then a.slopes.tempC=10
    else a.elapsed=1 end
    assert(not Core.validApproval(a,d,1000000),kind)
  end
end)
test('irregular peripheral timing includes final measurement endpoint',function()
  local e,d=Core.new(),data()
  local now=0
  for i=1,4000 do
    now=now+({.31,.44,.53,.28,.39})[(i-1)%5+1]
    e:step(d,now,1000000+now*1000)
    assert(not e.lock,e.lock and e.lock.reason)
  end
  assert(e.phase=='APROVADO' and math.abs(e.result.slopes.tempC)<1e-10)
  assert(e.result.sampleCount>=300 and e.result.elapsed==600)
end)
test('initial coolant redistribution may settle before the long window clears',function()
  for _, recover in ipairs({false,true}) do
    local e,d=Core.new(),data()
    local function trajectory(s,t)
      local dip=.004*math.min(t/20,1)
      local returned=recover and .004*math.max(0,math.min((t-20)/100,1)) or 0
      s.coolant=.8-dip+returned
    end
    run(e,d,0,60,trajectory)
    assert(not e.lock and e.phase=='ESTABILIZANDO')
    assert(e.long.coolant < -0.000002 and e.trial.settle==0)
    run(e,d,60.25,1000,trajectory)
    assert(not e.lock and e.phase=='APROVADO')
  end
end)
test('initial redistribution outside start margins is not exempted',function()
  local e,d=Core.new(),data()
  run(e,d,0,100,function(s,t) s.coolant=.51-.02*math.min(t/20,1) end)
  assert(e.lock and e.lock.reason=='RESERVA DE REFRIGERANTE DIMINUINDO')
end)
test('redistribution still falling at the long-window check trips',function()
  local e,d=Core.new(),data()
  run(e,d,0,100,function(s,t) s.coolant=.8-.004*math.min(t/80,1) end)
  assert(e.lock and e.lock.reason=='RESERVA DE REFRIGERANTE DIMINUINDO')
end)
test('redistribution exception does not apply after approval',function()
  local e,d=Core.new(),data()
  run(e,d,0,781)
  run(e,d,782,900,function(s,t) s.coolant=.8-.004*math.min((t-782)/20,1) end)
  assert(e.lock and next(e.approvals)==nil)
end)
test('coolant redistribution also waits through reference revalidation',function()
  local d=data()
  local a=approval(d)
  local e=Core.new({[Core.key(d.burn,d.signature)]=a})
  run(e,d,0,60,function(s,t) s.coolant=.8-.004*math.min(t/20,1) end)
  assert(not e.lock and e.phase=='REVALIDANDO' and e.trial.settle==0)
  run(e,d,60.25,250)
  assert(not e.lock and e.phase=='APROVADO' and e.cached==a)
end)
test('renewed coolant loss during recovery trips despite positive short regression',function()
  local e,d=Core.new(),data()
  run(e,d,0,60,function(s,t)
    s.coolant=.8-.004*math.min(t/20,1)+.004*math.max(0,math.min((t-20)/100,1))
  end)
  assert(not e.lock and e.guardShort.coolant>0 and e.guardLong.coolant<-.000002)
  d.coolant=d.coolant-.00001
  e:step(d,60.25,1060250)
  assert(e.lock and e.lock.reason=='RESERVA DE REFRIGERANTE DIMINUINDO')
end)
print(string.format('%d core scenarios passed',passed))
