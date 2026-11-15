local here=(debug.getinfo(1,'S').source:sub(2):match('^(.*[/\\])') or '')
local Logic=dofile(here..'../test_logic.lua')
local total=0
local function test(name,fn)
  local ok,err=pcall(fn) assert(ok,name..': '..tostring(err))
  total=total+1 print('OK '..name)
end
local tanks={'coolant','fuel','heated','waste'}
local function data()
  local d={active=true,tempC=100,damage=0,burn=.5,actual=.5,maxBurn=1920,
    coolant=.8,fuel=.8,heated=.1,waste=.1,signature='sodium-reactor-A',
    coolantCapacity=533200000,fuelCapacity=15360000,heatedCapacity=533200000,wasteCapacity=15360000}
  for _,k in ipairs(tanks) do d[k..'Amount']=d[k]*d[k..'Capacity'] end return d
end
local function level(d,key,v) d[key]=v d[key..'Amount']=v*d[key..'Capacity'] end
local function raw(d,key,v) d[key..'Amount']=v d[key]=v/d[key..'Capacity'] end
local function armed(config) local e=Logic.new(config) assert(e:startTest()) return e end
local function run(e,d,a,b,change)
  for i=a*4,b*4 do
    local t=i/4
    if change then change(d,t) end
    local why=e:step(d,t,1000000+t*1000)
    if why then return why,t end
  end
end
test('explicit test alone enables measurement and validates a stable exact rate',function()
  local e,d=Logic.new(),data()
  run(e,d,0,800)
  assert(e.state=='IDLE')
  assert(e:startTest())
  run(e,d,800.25,1579)
  assert(e.state=='MEASURING' and e.elapsed<600)
  run(e,d,1579.25,1581)
  assert(e.state=='PASSED' and e.target==.5 and e.elapsed==600)
end)
test('startup coolant redistribution with plateau or recovery does not falsely trip',function()
  for _,recover in ipairs({false,true}) do
    local e,d=armed(),data()
    run(e,d,0,1200,function(s,t)
      level(s,'coolant',.8-.004*math.min(t/20,1)+(recover and .004*math.max(0,math.min((t-20)/100,1)) or 0))
    end)
    assert(not e.failure,e.failure)
    assert(e.state=='PASSED')
  end
end)
test('a huge finite fuel buffer without input never passes at 0.5mB/t',function()
  local e,d=armed(),data()
  local initial=d.fuelAmount
  run(e,d,0,800,function(s,t) raw(s,'fuel',initial-t*.5*20) end)
  assert(e.failure and e.state=='FAILED' and e.elapsed<600)
  assert(e.failure:find('fuel'))
end)
test('huge coolant capacity cannot hide a one mB per second deficit',function()
  local e,d=armed(),data()
  local initial=d.coolantAmount
  run(e,d,0,800,function(s,t) raw(s,'coolant',initial-t) end)
  assert(e.failure and e.failure:find('coolant'))
end)
test('refill pulses with a net fuel deficit cannot disguise missing supply',function()
  local e,d=armed(),data()
  local initial=d.fuelAmount
  run(e,d,0,800,function(s,t) raw(s,'fuel',initial-t*10+math.floor(t)*9) end)
  assert(e.failure and e.state~='PASSED')
end)
test('small balanced replenishment cycles within raw quantization remain measurable',function()
  local e,d=armed(),data()
  local initial=d.fuelAmount
  run(e,d,0,1000,function(s,t) raw(s,'fuel',initial-.1*(t%2)) end)
  assert(not e.failure,e.failure)
  assert(e.state=='PASSED')
end)
test('balanced 100mB replenishment pulses at 0.5mB per tick pass',function()
  local e,d=armed(),data()
  local initial=d.fuelAmount
  run(e,d,0,1000,function(s,t) raw(s,'fuel',initial-10*(t%10)) end)
  assert(not e.failure,e.failure)
  assert(e.state=='PASSED')
end)
test('irregular timing includes the final endpoint of the complete measurement',function()
  local e,d=armed(),data()
  local t=0
  for i=1,2500 do
    t=t+({.31,.44,.53,.28,.39})[(i-1)%5+1]
    assert(not e:step(d,t,1000000+t*1000),e.failure)
  end
  assert(e.state=='PASSED' and e.stats.sampleCount>=300)
  assert(math.abs(e.stats.slopes.tempC)<1e-10)
end)
test('changed configured rate discards progress and evaluates the new rate exactly',function()
  local e,d=armed(),data()
  run(e,d,0,300)
  assert(e.state=='MEASURING')
  d.burn,d.actual=1.5,1.5
  run(e,d,300.25,301)
  assert(not e.failure and e.target==1.5 and e.elapsed==0)
  run(e,d,301.25,1082)
  assert(e.state=='PASSED' and e.target==1.5)
end)
test('changing rate after PASSED removes that approval and restarts a full trial',function()
  local e,d=armed(),data()
  run(e,d,0,781)
  assert(e.state=='PASSED')
  d.burn,d.actual=1,1
  run(e,d,781.25,782)
  assert(e.state=='WARMUP' and e.elapsed==0 and e.target==1)
end)
test('actual fuel starvation cannot pass even with configured burn unchanged',function()
  local e,d=armed(),data()
  d.actual=.25
  local why,t=run(e,d,0,20)
  assert(why=='QUEIMA REAL DIFERENTE DA CONFIGURADA' and t<=5)
end)
test('actual mismatch is immediate during measuring and after passing',function()
  for _,untilTime in ipairs({200,781}) do
    local e,d=armed(),data()
    run(e,d,0,untilTime)
    d.actual=.4
    local why=run(e,d,untilTime+.25,untilTime+.25)
    assert(why=='QUEIMA REAL DIFERENTE DA CONFIGURADA')
  end
end)
test('hard faults and invalid fields fail even when testing is disabled',function()
  local mutations={
    function(d) d.tempC=600 end,function(d) d.damage=.01 end,
    function(d) level(d,'coolant',.19) end,function(d) level(d,'fuel',.09) end,
    function(d) level(d,'heated',.85) end,function(d) level(d,'waste',.75) end,
    function(d) d.tempC=0/0 end,function(d) d.actual=math.huge end,
    function(d) d.fuelCapacity=nil end,function(d) d.coolantAmount=-1 end,
    function(d) d.heatedAmount=d.heatedCapacity+1 end,function(d) d.active=nil end,
    function(d) d.signature='' end,
  }
  for i,change in ipairs(mutations) do
    local e,d=Logic.new(),data() change(d)
    assert(e:step(d,0,1000000),i)
    assert(e.state=='FAILED')
  end
end)
test('new trial requires start margins without counting partial unsafe progress',function()
  local e,d=armed(),data()
  level(d,'coolant',.25)
  assert(e:step(d,0,1000000)=='MARGENS INSUFICIENTES PARA INICIAR TESTE')
end)
test('protective prediction acts before a hard temperature or coolant limit',function()
  for _,field in ipairs({'tempC','coolant'}) do
    local e,d=Logic.new(),data()
    run(e,d,0,60,function(s,t)
      if field=='tempC' then s.tempC=100+t*10 else level(s,'coolant',.8-t*.02) end
    end)
    assert(e.failure=='LIMITE PREVISTO: '..field,e.failure)
    assert(d.tempC<600 and d.coolant>=.2)
  end
end)
test('outside-test operation still trips on sustained raw loss',function()
  local e,d=Logic.new(),data()
  local initial=d.fuelAmount
  run(e,d,0,200,function(s,t) raw(s,'fuel',initial-t*10) end)
  assert(e.failure and e.failure:find('fuel'))
end)
test('warmup cannot be extended forever even by repeatedly requesting tests',function()
  local e,d=Logic.new(),data()
  run(e,d,0,1900,function(s,t)
    s.tempC=100+t*.02
    if t%20==0 then e:startTest() end
  end)
  assert(e.failure=='OPERACAO SEM EQUILIBRIO: TEMPO ESGOTADO',e.failure)
end)
test('rate changes do not erase ongoing protection evidence',function()
  local e,d=armed(),data()
  local initial=d.coolantAmount
  run(e,d,0,200,function(s,t)
    s.burn=.5+math.floor(t)%2 s.actual=s.burn
    raw(s,'coolant',initial-t)
  end)
  assert(e.failure and e.failure:find('coolant'))
end)
test('raw loss after approval revokes approval before fraction thresholds hide it',function()
  local e,d=armed(),data()
  run(e,d,0,781)
  assert(e.state=='PASSED')
  raw(d,'fuel',d.fuelAmount-3)
  assert(e:step(d,781.25,1781250):find('fuel'))
  assert(e.state=='FAILED')
end)
test('raw drift during measurement fails before full-span completion',function()
  local e,d=armed(),data()
  run(e,d,0,200)
  raw(d,'coolant',d.coolantAmount-3)
  assert(e:step(d,200.25,1200250):find('coolant'))
end)
test('normal shutdown counts no idle seconds and resumes a fresh trial',function()
  local e,d=armed(),data()
  run(e,d,0,300)
  d.active=false
  run(e,d,300.25,1000)
  assert(e.state=='WAITING' and e.elapsed==0)
  d.active=true
  run(e,d,1000.25,1001)
  assert(e.elapsed==0 and e.state=='WARMUP')
end)
test('cancel test retains safety and restart explicitly arms a new test',function()
  local e,d=armed(),data()
  run(e,d,0,200)
  assert(e:cancelTest('OPERADOR'))
  assert(e.state=='CANCELLED' and e.reason=='OPERADOR')
  run(e,d,200.25,201)
  assert(e.state=='CANCELLED')
  assert(e:startTest())
  run(e,d,201.25,202)
  assert(e.elapsed==0 and e.state=='WARMUP')
  d.damage=.1
  assert(e:step(d,202.25,1202250))
end)
test('gaps and clock rollback never become valid measured time',function()
  for _,kind in ipairs({'gap','utc','back'}) do
    local e,d=armed(),data()
    e:step(d,0,1000000)
    local now,utc=1,1001000
    if kind=='gap' then now,utc=6,1006000 elseif kind=='utc' then utc=1010000 else now=-1 end
    assert(e:step(d,now,utc)=='INTERVALO SEM LEITURAS CONFIAVEIS')
  end
end)
test('signature changes trip during operation and failures stay latched',function()
  local e,d=armed(),data()
  run(e,d,0,5)
  d.signature='new-capacity'
  assert(e:step(d,5.25,1005250)=='CONFIGURACAO DO REATOR MUDOU')
  d.signature='sodium-reactor-A'
  assert(e:step(d,5.5,1005500)=='CONFIGURACAO DO REATOR MUDOU')
  assert(not e:startTest())
  e:resetAfterFault()
  d.active=false
  assert(not e:step(d,6,1006000) and e.state=='IDLE')
end)
test('histories stay bounded during long supervision',function()
  local e,d=armed(),data()
  run(e,d,0,4000)
  assert(e.state=='PASSED')
  assert(#e.guards<=68 and #e.testSamples<=68 and #e.measureSamples<=602 and #e.envelopeSamples<=2048)
end)
test('status snapshots cannot mutate the evaluator',function()
  local e,d=armed(),data()
  run(e,d,0,781)
  local status=e:status()
  status.stats.minRaw.fuel=-100 status.slopes.tempC=999
  assert(e.stats.minRaw.fuel>0 and e.slopes.tempC<1)
end)
test('invalid configuration fails closed at construction',function()
  for _,config in ipairs({{SAMPLE_SECONDS=0},{COOLANT_START_MIN=.1},{MEASURE_SECONDS=10},
    {TANK_RAW_NOISE=0/0},{MAX_SAMPLE_GAP=-1}}) do assert(not pcall(Logic.new,config)) end
end)
test('balanced 100mB pulses with a net one mB per second deficit fail',function()
  local e,d=armed(),data()
  local initial=d.fuelAmount
  run(e,d,0,1000,function(s,t) raw(s,'fuel',initial-10*t+90*math.floor(t/10)) end)
  assert(e.failure and e.state~='PASSED')
end)
test('temperature start margin is admission only, not a hidden pass ceiling',function()
  local e,d=armed(),data()
  run(e,d,0,1200,function(s,t) s.tempC=100+300*math.min(t/100,1) end)
  assert(not e.failure,e.failure)
  assert(e.state=='PASSED' and d.tempC==400)
end)
test('terminal statuses expose result UTC timestamps',function()
  local e,d=armed(),data()
  run(e,d,0,781)
  assert(type(e:status().resultUtc)=='number')
  e:cancelTest('MANUAL')
  assert(e:status().resultUtc==e.lastUTC)
  e:fail('EXTERNA')
  assert(e:status().resultUtc==e.lastUTC)
end)
test('balanced 10mB one-second pulses do not alias into a false trough fault',function()
  local e,d=armed(),data()
  local initial=d.fuelAmount
  run(e,d,0,1000,function(s,t) raw(s,'fuel',initial-10*(t%1)) end)
  assert(not e.failure,e.failure)
  assert(e.state=='PASSED')
end)
test('new operating rate reopens the coolant envelope while retaining guards',function()
  local e,d=armed(),data()
  run(e,d,0,781)
  assert(e.state=='PASSED')
  d.burn,d.actual=1,1
  run(e,d,781.25,1900,function(s,t)
    local since=t-781.25
    level(s,'coolant',.8-.004*math.min(since/20,1)+.004*math.max(0,math.min((since-20)/100,1)))
  end)
  assert(not e.failure,e.failure)
  assert(e.state=='PASSED' and e.target==1)
end)
test('a single large replenishment burst cannot masquerade as repeated stable cycles',function()
  local e,d=armed(),data()
  local initial=d.fuelAmount
  run(e,d,0,1000,function(s,t)
    local burst=math.min(t/10,1)*10000
    raw(s,'fuel',initial+burst-t*10)
  end)
  assert(e.failure and e.state~='PASSED')
end)
test('a startup burst followed by deficient pulses cannot inflate the learned envelope',function()
  local e,d=armed(),data()
  local initial=d.fuelAmount
  run(e,d,0,1000,function(s,t)
    local burst=math.min(t/10,1)*10000
    raw(s,'fuel',initial+burst-10*t+50*math.floor(t/10))
  end)
  assert(e.failure and e.state~='PASSED')
end)
print(total..' fission logic scenarios passed')
