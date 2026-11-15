-- Pure safety/test evaluator. No peripheral, filesystem, network or control calls.
-- Temperatures are Celsius; tank levels are fractions; slopes are units/second.
local M = {}
M.defaults = {
  TEMP_SCRAM_C=600, TEMP_START_MAX_C=350, DAMAGE_MAX=0,
  COOLANT_MIN=.20, COOLANT_START_MIN=.30, FUEL_MIN=.10, FUEL_START_MIN=.25,
  HEATED_MAX=.85, HEATED_START_MAX=.50, WASTE_MAX=.75, WASTE_START_MAX=.50,
  TREND_WINDOW=60, SHORT_WINDOW=10, STABLE_SECONDS=120, MEASURE_SECONDS=600,
  TEST_TIMEOUT=1800, PREDICT_SECONDS=60, TEMP_SLOPE_MAX=.01,
  TANK_SLOPE_MAX=.000001, TEMP_RANGE_MAX=3, TANK_DRIFT_MAX=.0005,
  SAMPLE_SECONDS=1, MAX_SAMPLE_GAP=5, TANK_RAW_NOISE=2,
}
local fields = {'tempC','coolant','fuel','heated','waste'}
local directions = {tempC=1,coolant=-1,fuel=-1,heated=1,waste=1}
local tanks={'coolant','fuel','heated','waste'}
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function copy(t)
  if type(t)~='table' then return t end
  local out={} for k,v in pairs(t) do out[k]=copy(v) end return out
end
local function same(a,b) return finite(a) and finite(b) and math.abs(a-b)<=.000001 end
local function sample(d,t)
  local s={t=t} for _,k in ipairs(fields) do s[k]=d[k] end
  for _,k in ipairs(tanks) do s[k..'Amount']=d[k..'Amount'] end
  return s
end
local function regression(samples,key,span)
  local last=samples[#samples]
  if not last then return nil end
  local cutoff=last.t-span
  local first=1
  -- Include the sample at/before the left endpoint, never fabricate a span.
  while first<#samples and samples[first+1].t<=cutoff do first=first+1 end
  if last.t-samples[first].t<span-1e-7 or #samples-first+1<3 then return nil end
  local n,sx,sy,sxx,sxy=0,0,0,0,0
  for i=first,#samples do
    local s=samples[i]
    local x,y=s.t-last.t,s[key]
    n,sx,sy,sxx,sxy=n+1,sx+x,sy+y,sxx+x*x,sxy+x*y
  end
  local den=n*sxx-sx*sx
  if den<=0 then return nil end
  return (n*sxy-sx*sy)/den
end
local function slopes(samples,span)
  local out={} for _,k in ipairs(fields) do out[k]=regression(samples,k,span) end return out
end
local function stable(s,c)
  if not s.tempC then return false end
  return s.tempC<=c.TEMP_SLOPE_MAX and s.coolant>=-c.TANK_SLOPE_MAX and
    s.fuel>=-c.TANK_SLOPE_MAX and s.heated<=c.TANK_SLOPE_MAX and s.waste<=c.TANK_SLOPE_MAX
end
local function rawSlopes(samples,span)
  local out={} for _,k in ipairs(tanks) do out[k]=regression(samples,k..'Amount',span) end return out
end
local function rawEnvelope(samples,span,c)
  local envelope={}
  local last=samples[#samples]
  if not last then return envelope end
  local first=1
  while first<#samples and samples[first+1].t<=last.t-span do first=first+1 end
  for _,k in ipairs(tanks) do
    local key=k..'Amount'
    local lo,hi,lastDirection=samples[first][key],samples[first][key],nil
    local turns={}
    for i=first+1,#samples do
      local value=samples[i][key]
      lo,hi=math.min(lo,value),math.max(hi,value)
      local change=value-samples[i-1][key]
      local direction=change>c.TANK_RAW_NOISE and 1 or (change < -c.TANK_RAW_NOISE and -1 or nil)
      if direction then
        if lastDirection and direction~=lastDirection then
          turns[#turns+1]={value=samples[i-1][key],direction=lastDirection}
        end
        lastDirection=direction
      end
    end
    local allowance,stationary,cycles=0,true,0
    if #turns>=6 then
      -- Only the latest three COMPLETE oscillations may set a pulse envelope.
      -- A single large startup burst must not inflate that learned allowance.
      local lows,highs={},{}
      local cycleMin,cycleMax=math.huge,-math.huge
      for i=#turns-5,#turns do
        local turn=turns[i]
        cycleMin,cycleMax=math.min(cycleMin,turn.value),math.max(cycleMax,turn.value)
        local dest=turn.direction==-1 and lows or highs
        dest[#dest+1]=turn.value
      end
      stationary=math.abs(lows[#lows]-lows[1])<=c.TANK_RAW_NOISE and
        math.abs(highs[#highs]-highs[1])<=c.TANK_RAW_NOISE
      cycles=3
      if stationary then lo,hi,allowance=cycleMin,cycleMax,cycleMax-cycleMin end
    end
    envelope[k]={min=lo,max=hi,cycles=cycles,stationary=stationary,allowance=allowance}
  end
  return envelope
end
local function rawStable(s,span,c,envelope)
  for _,k in ipairs(tanks) do
    local bound=envelope and envelope[k]
    if bound and not bound.stationary then return false end
    local excursion=bound and bound.allowance or 0
    if not finite(s[k]) or s[k]*directions[k]>(c.TANK_RAW_NOISE+excursion)/span then return false end
  end
  return true
end
local function windowStable(samples,span,c,envelope)
  return stable(slopes(samples,span),c) and rawStable(rawSlopes(samples,span),span,c,envelope)
end
local function outsideEnvelope(d,envelope,c)
  for _,k in ipairs(tanks) do
    local bound=envelope[k]
    if directions[k]==-1 and d[k..'Amount']<bound.min-c.TANK_RAW_NOISE or
      directions[k]==1 and d[k..'Amount']>bound.max+c.TANK_RAW_NOISE then return k end
  end
end
local function valid(d)
  if type(d)~='table' or type(d.active)~='boolean' or type(d.signature)~='string' or d.signature=='' then
    return 'LEITURA INCOMPLETA'
  end
  for _,k in ipairs({'tempC','damage','burn','actual','maxBurn','coolant','fuel','heated','waste'}) do
    if not finite(d[k]) then return 'LEITURA INVALIDA: '..k end
  end
  for _,k in ipairs(tanks) do
    if not finite(d[k..'Amount']) or not finite(d[k..'Capacity']) or d[k..'Capacity']<=0 or
      d[k..'Amount']<0 or d[k..'Amount']>d[k..'Capacity'] then return 'TANQUE BRUTO INVALIDO: '..k end
    if d[k]<0 or d[k]>1 then return 'NIVEL FORA DA FAIXA: '..k end
    if math.abs(d[k]-d[k..'Amount']/d[k..'Capacity'])>1e-8 then return 'NIVEL INCONSISTENTE: '..k end
  end
  if d.tempC < -273.15 or d.damage<0 or d.damage>100 or d.burn<0 or d.actual<0 or
    d.maxBurn<=0 or d.burn>d.maxBurn+.000001 or d.actual>d.maxBurn+.000001 then
    return 'LEITURA FORA DA FAIXA'
  end
end
local function hard(d,c)
  local why=valid(d) if why then return why end
  if d.damage>c.DAMAGE_MAX then return 'DANO NO REATOR' end
  if d.tempC>=c.TEMP_SCRAM_C then return 'TEMPERATURA ALTA' end
  if d.coolant<c.COOLANT_MIN then return 'REFRIGERANTE FRIO INSUFICIENTE' end
  if d.heated>=c.HEATED_MAX then return 'REFRIGERANTE QUENTE ACUMULADO' end
  if d.waste>=c.WASTE_MAX then return 'RESIDUOS ACUMULADOS' end
  if d.active and d.fuel<c.FUEL_MIN then return 'COMBUSTIVEL INSUFICIENTE' end
end
local function startMargins(d,c)
  return d.tempC<=c.TEMP_START_MAX_C and d.coolant>=c.COOLANT_START_MIN and
    d.fuel>=c.FUEL_START_MIN and d.heated<=c.HEATED_START_MAX and d.waste<=c.WASTE_START_MAX
end
local function prediction(d,s,c)
  if not s.tempC then return nil end
  local limits={tempC=c.TEMP_SCRAM_C,coolant=c.COOLANT_MIN,fuel=c.FUEL_MIN,heated=c.HEATED_MAX,waste=c.WASTE_MAX}
  for _,k in ipairs(fields) do
    local noise=k=='tempC' and c.TEMP_SLOPE_MAX or c.TANK_RAW_NOISE/d[k..'Capacity']/c.SHORT_WINDOW
    if s[k]*directions[k]>noise then
      local eta=(limits[k]-d[k])/s[k]
      if eta>=0 and eta<=c.PREDICT_SECONDS then return 'LIMITE PREVISTO: '..k end
    end
  end
end
function M.new(config)
  local c=copy(M.defaults)
  for k in pairs(c) do if config and config[k]~=nil then c[k]=config[k] end end
  for k,v in pairs(c) do assert(finite(v) and v>=0,'Configuracao invalida: '..k) end
  assert(c.SAMPLE_SECONDS>0 and c.SHORT_WINDOW>=c.SAMPLE_SECONDS*2 and c.TREND_WINDOW>=c.SHORT_WINDOW,
    'Janelas de tendencia invalidas')
  assert(c.MAX_SAMPLE_GAP>=c.SAMPLE_SECONDS and c.MEASURE_SECONDS>=c.TREND_WINDOW and
    c.STABLE_SECONDS>0 and c.TEST_TIMEOUT>c.STABLE_SECONDS+c.MEASURE_SECONDS+c.TREND_WINDOW,
    'Duracoes de teste invalidas')
  assert(c.COOLANT_MIN<c.COOLANT_START_MIN and c.COOLANT_START_MIN<=1 and
    c.FUEL_MIN<c.FUEL_START_MIN and c.FUEL_START_MIN<=1 and
    c.HEATED_START_MAX<c.HEATED_MAX and c.HEATED_MAX<=1 and
    c.WASTE_START_MAX<c.WASTE_MAX and c.WASTE_MAX<=1 and c.TEMP_START_MAX_C<c.TEMP_SCRAM_C,
    'Margens de seguranca invalidas')
  local e={config=c}
  function e:resetAfterFault()
    self.state,self.reason='IDLE',nil
    self.enabled,self.failure=false,nil
    self.guards,self.testSamples,self.measureSamples,self.envelopeSamples={},{},{},{}
    self.lastTime,self.lastUTC,self.sampleAt,self.lastActive=nil,nil,nil,nil
    self.signature,self.activityStart,self.operationSettled=nil,nil,false
    self.operatingEnvelope,self.lastBurn,self.warmupAt=nil,nil,nil
    self.target,self.settle,self.elapsed=nil,0,0
    self.ready,self.measureAt,self.trialStart,self.mismatch=nil,nil,nil,nil
    self.slopes,self.short,self.stats={},{},nil
    self.rawLong,self.rawShort={},{}
    self.startedUtc,self.finishedUtc,self.resultUtc=nil,nil,nil
  end
  function e:fail(reason,utc)
    if not self.failure then
      self.failure,self.reason,self.state=reason,reason,'FAILED'
      self.finishedUtc=finite(utc) and utc or self.lastUTC
      self.resultUtc=self.finishedUtc
    end
    return self.failure
  end
  function e:startTest()
    if self.failure then return false,self.failure end
    self.enabled,self.state,self.reason=true,'WAITING','AGUARDANDO ATIVACAO MANUAL'
    self.target,self.settle,self.elapsed=nil,0,0
    self.testSamples,self.measureSamples={},{}
    self.ready,self.measureAt,self.trialStart,self.stats=nil,nil,nil,nil
    self.startedUtc,self.finishedUtc,self.resultUtc=nil,nil,nil
    return true
  end
  function e:cancelTest(reason)
    if self.failure then return false,self.failure end
    self.enabled,self.state,self.reason=false,'CANCELLED',reason or 'TESTE CANCELADO'
    self.ready=nil
    self.resultUtc,self.finishedUtc=self.lastUTC,self.lastUTC
    return true
  end
  function e:status()
    return copy({state=self.state,target=self.target,settle=self.settle,elapsed=self.elapsed,
      duration=c.MEASURE_SECONDS,reason=self.reason,slopes=self.slopes,stats=self.stats,
      resultUtc=self.resultUtc,rawSlopes=self.rawLong,startedUtc=self.startedUtc,finishedUtc=self.finishedUtc,stableSeconds=c.STABLE_SECONDS})
  end
  local function trim(samples,now)
    while #samples>2 and samples[2].t<now-c.TREND_WINDOW-c.MAX_SAMPLE_GAP do table.remove(samples,1) end
    local bound=math.ceil((c.TREND_WINDOW+c.MAX_SAMPLE_GAP)/c.SAMPLE_SECONDS)+3
    while #samples>bound do table.remove(samples,1) end
  end
  local function addStats(stats,d)
    for _,k in ipairs(fields) do
      stats.min[k],stats.max[k]=math.min(stats.min[k],d[k]),math.max(stats.max[k],d[k])
    end
    for _,k in ipairs(tanks) do
      stats.minRaw[k],stats.maxRaw[k]=math.min(stats.minRaw[k],d[k..'Amount']),math.max(stats.maxRaw[k],d[k..'Amount'])
    end
  end
  local function excessiveDrift(stats,d)
    for _,k in ipairs(tanks) do
      local bound=stats.envelope[k]
      if directions[k]==-1 and stats.minRaw[k]<bound.min-c.TANK_RAW_NOISE or
        directions[k]==1 and stats.maxRaw[k]>bound.max+c.TANK_RAW_NOISE then return 'PERDA OU ACUMULO BRUTO: '..k end
    end
    if stats.max.tempC-stats.min.tempC>c.TEMP_RANGE_MAX then return 'TEMPERATURA NAO ESTABILIZOU' end
    if stats.initial.coolant-stats.min.coolant>c.TANK_DRIFT_MAX or
      stats.initial.fuel-stats.min.fuel>c.TANK_DRIFT_MAX or
      stats.max.heated-stats.initial.heated>c.TANK_DRIFT_MAX or
      stats.max.waste-stats.initial.waste>c.TANK_DRIFT_MAX then return 'RESERVAS NAO SUSTENTAVEIS' end
  end
  function e:step(d,now,utc)
    if self.failure then return self.failure end
    local why=hard(d,c) if why then return self:fail(why,utc) end
    if not finite(now) or not finite(utc) then return self:fail('RELOGIO INVALIDO',utc) end
    if self.lastTime and (now<self.lastTime or utc<self.lastUTC or
      now-self.lastTime>c.MAX_SAMPLE_GAP or utc-self.lastUTC>c.MAX_SAMPLE_GAP*1000) then
      return self:fail('INTERVALO SEM LEITURAS CONFIAVEIS',utc)
    end
    self.lastTime,self.lastUTC=now,utc
    if not d.active then
      self.guards,self.testSamples,self.measureSamples,self.envelopeSamples={},{},{},{}
      self.sampleAt,self.activityStart,self.signature=nil,nil,nil
      self.operationSettled,self.lastActive=false,false
      self.operatingEnvelope,self.lastBurn,self.warmupAt=nil,nil,nil
      self.slopes,self.short,self.rawLong,self.rawShort={},{},{},{}
      self.mismatch,self.ready,self.measureAt,self.trialStart=nil,nil,nil,nil
      if self.enabled then
        self.state,self.reason='WAITING','REATOR DESLIGADO; AGUARDANDO ATIVACAO MANUAL'
        self.target,self.settle,self.elapsed,self.stats=nil,0,0,nil
      end
      return
    end
    if d.burn<=0 then return self:fail('QUEIMA ZERO COM REATOR ATIVO',utc) end
    if self.signature and self.signature~=d.signature then return self:fail('CONFIGURACAO DO REATOR MUDOU',utc) end
    self.signature=d.signature
    self.activityStart=self.activityStart or now
    self.warmupAt=self.warmupAt or now
    if self.lastBurn and not same(self.lastBurn,d.burn) then
      -- New operating point: reopen equilibration, but preserve all protection
      -- samples. Repeated changes while warming cannot renew its deadline.
      if self.operationSettled then self.warmupAt=now end
      self.operationSettled,self.operatingEnvelope=false,nil
    end
    self.lastBurn=d.burn
    self.lastActive=true
    if self.enabled and (not self.target or not same(self.target,d.burn)) then
      if not startMargins(d,c) then return self:fail('MARGENS INSUFICIENTES PARA INICIAR TESTE',utc) end
      self.target,self.trialStart,self.startedUtc=d.burn,now,utc
      self.state,self.reason='WARMUP','AGUARDANDO EQUILIBRIO DE TEMPERATURA E RESERVAS'
      self.settle,self.elapsed=0,0
      self.ready,self.measureAt,self.stats,self.finishedUtc,self.resultUtc=nil,nil,nil,nil,nil
      self.testSamples,self.measureSamples={},{}
    end
    -- Capture extrema at every accepted snapshot, not only the regression
    -- cadence: a pump trough can occur between one-second trend samples.
    self.envelopeSamples[#self.envelopeSamples+1]=sample(d,now)
    while #self.envelopeSamples>2 and self.envelopeSamples[2].t<now-c.TREND_WINDOW-c.MAX_SAMPLE_GAP do
      table.remove(self.envelopeSamples,1)
    end
    while #self.envelopeSamples>2048 do table.remove(self.envelopeSamples,1) end
    local sampled=false
    if not self.sampleAt or now-self.sampleAt>=c.SAMPLE_SECONDS-1e-8 then
      self.guards[#self.guards+1]=sample(d,now) self.sampleAt=now sampled=true
      trim(self.guards,now)
      self.short,self.slopes=slopes(self.guards,c.SHORT_WINDOW),slopes(self.guards,c.TREND_WINDOW)
      self.rawShort,self.rawLong=rawSlopes(self.guards,c.SHORT_WINDOW),rawSlopes(self.guards,c.TREND_WINDOW)
    end
    local predicted=prediction(d,self.short,c)
    if predicted then return self:fail(predicted,utc) end
    if not same(d.actual,d.burn) then
      self.mismatch=self.mismatch or now
      self.ready,self.settle=nil,0
      if self.state=='MEASURING' or self.state=='PASSED' or self.operationSettled or now-self.mismatch>=5 then
        return self:fail('QUEIMA REAL DIFERENTE DA CONFIGURADA',utc)
      end
      self.reason='AGUARDANDO QUEIMA REAL IGUAL A CONFIGURADA'
      return
    end
    self.mismatch=nil
    local observedEnvelope=rawEnvelope(self.envelopeSamples,c.TREND_WINDOW,c)
    if not self.operationSettled and now-self.warmupAt>=c.TREND_WINDOW and
      windowStable(self.guards,c.TREND_WINDOW,c,observedEnvelope) and
      windowStable(self.guards,c.SHORT_WINDOW,c,observedEnvelope) then
      self.operationSettled=true
      self.operatingEnvelope=copy(observedEnvelope)
    end
    if self.operatingEnvelope then
      local outside=outsideEnvelope(d,self.operatingEnvelope,c)
      if outside then return self:fail('RESERVA FORA DO ENVELOPE OBSERVADO: '..outside,utc) end
    end
    if not self.operationSettled and now-self.warmupAt>=c.TEST_TIMEOUT then
      return self:fail('OPERACAO SEM EQUILIBRIO: TEMPO ESGOTADO',utc)
    end
    -- A one-off startup draw may recover before a long regression forgets it.
    -- Once equilibrium was observed, sustained tank loss remains a protection
    -- even without an explicit test and survives retests/rate changes.
    if self.slopes.tempC and self.short.tempC then
      for _,k in ipairs({'coolant','fuel','heated','waste'}) do
        local allowance=c.TANK_RAW_NOISE+(observedEnvelope[k] and observedEnvelope[k].allowance or 0)
        local rawLoss=self.rawLong[k]*directions[k]>allowance/c.TREND_WINDOW and
          self.rawShort[k]*directions[k]>c.TANK_RAW_NOISE/c.SHORT_WINDOW
        local fractionLoss=self.operationSettled and self.slopes[k]*directions[k]>c.TANK_SLOPE_MAX*2 and
          self.short[k]*directions[k]>c.TANK_SLOPE_MAX
        local newCoolantWindow=k=='coolant' and not self.operationSettled and now-self.warmupAt<c.TREND_WINDOW
        if (rawLoss or fractionLoss) and not newCoolantWindow then
          return self:fail('TENDENCIA ADVERSA SUSTENTADA: '..k,utc)
        end
      end
    end
    if not self.enabled then return end
    if sampled or #self.testSamples==0 then
      self.testSamples[#self.testSamples+1]=sample(d,now) trim(self.testSamples,now)
    end
    local short,long=slopes(self.testSamples,c.SHORT_WINDOW),slopes(self.testSamples,c.TREND_WINDOW)
    local trialEnvelope=rawEnvelope(self.envelopeSamples,c.TREND_WINDOW,c)
    local evaluationEnvelope=self.stats and self.stats.envelope or trialEnvelope
    local isStable=windowStable(self.testSamples,c.SHORT_WINDOW,c,evaluationEnvelope) and
      windowStable(self.testSamples,c.TREND_WINDOW,c,evaluationEnvelope)
    if self.state=='PASSED' then
      addStats(self.stats,d)
      why=excessiveDrift(self.stats,d)
      if why then return self:fail('APROVACAO REVOGADA: '..why,utc) end
      if not isStable then return self:fail('APROVACAO REVOGADA: TENDENCIA ADVERSA',utc) end
      return
    end
    if now-self.trialStart>=c.TEST_TIMEOUT then return self:fail('TESTE INCONCLUSIVO: TEMPO ESGOTADO',utc) end
    if self.state~='MEASURING' then
      if isStable then
        self.ready=self.ready or now
        self.settle=now-self.ready
        self.state,self.reason='STABILIZING','CONFIRMANDO EQUILIBRIO CONTINUO'
      else
        self.ready,self.settle=nil,0
        self.state,self.reason='WARMUP','AGUARDANDO EQUILIBRIO DE TEMPERATURA E RESERVAS'
      end
      if self.settle<c.STABLE_SECONDS then return end
      self.state,self.reason,self.measureAt='MEASURING','MEDINDO A TAXA ESCOLHIDA',now
      self.measureSamples={sample(d,now)}
      self.stats={initial={},min={},max={},slopes={},sampleCount=1,initialRaw={},minRaw={},maxRaw={},rawSlopes={},envelope=copy(trialEnvelope)}
      for _,k in ipairs(fields) do self.stats.initial[k],self.stats.min[k],self.stats.max[k]=d[k],d[k],d[k] end
      for _,k in ipairs(tanks) do self.stats.initialRaw[k],self.stats.minRaw[k],self.stats.maxRaw[k]=d[k..'Amount'],d[k..'Amount'],d[k..'Amount'] end
    end
    self.elapsed=math.min(c.MEASURE_SECONDS,now-self.measureAt)
    local last=self.measureSamples[#self.measureSamples]
    if now>last.t and (now-last.t>=c.SAMPLE_SECONDS-1e-8 or self.elapsed>=c.MEASURE_SECONDS) then
      self.measureSamples[#self.measureSamples+1]=sample(d,now)
    end
    addStats(self.stats,d)
    self.stats.sampleCount=#self.measureSamples
    why=excessiveDrift(self.stats,d)
    if why then return self:fail('TESTE: '..why,utc) end
    if not isStable then return self:fail('TESTE: TENDENCIA ADVERSA',utc) end
    if self.elapsed>=c.MEASURE_SECONDS then
      local total=slopes(self.measureSamples,now-self.measureAt)
      self.stats.slopes=total
      self.stats.rawSlopes=rawSlopes(self.measureSamples,now-self.measureAt)
      if not stable(total,c) or not rawStable(self.stats.rawSlopes,now-self.measureAt,c,self.stats.envelope) then return self:fail('TESTE INCONCLUSIVO: TENDENCIA COMPLETA ADVERSA',utc) end
      self.state,self.reason,self.finishedUtc='PASSED','ESTAVEL NO PERIODO OBSERVADO; PROTECAO CONTINUA',utc
      self.resultUtc=utc
    end
  end
  e:resetAfterFault()
  return e
end
M.finite,M.valid,M.hardFault,M.startMargins,M.same=finite,valid,hard,startMargins,same
return M
