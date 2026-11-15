-- Pure evaluation logic. No peripherals, filesystem, networking or activation.
local M = {}
M.policy = "auto-v2.2"
M.cfg = {
  period = 0.25, maxGap = 2, samplePeriod = 1,
  stabilize = 120, duration = 600, timeout = 1800,
  maxTempC = 450, minCoolant = 0.25, maxHeated = 0.85,
  maxWaste = 0.75, minFuel = 0.10,
  startTempC = 350, startCoolant = 0.50, startHeated = 0.50, startWaste = 0.50, startFuel = 0.25,
  maxTempSlope = 0.01, maxTankSlope = 0.000001,
  maxTempRange = 3, maxTankDrift = 0.0005,
  predictSeconds = 60, approvalTTL = 6 * 60 * 60 * 1000,
}
local C = M.cfg
function M.finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
function M.same(a, b) return M.finite(a) and M.finite(b) and math.abs(a-b) <= 1e-8 end
function M.key(rate, signature) return signature .. "|" .. string.format("%.17g", rate) end
function M.valid(d)
  if type(d) ~= "table" or type(d.active) ~= "boolean" or type(d.signature) ~= "string" then
    return "LEITURA INCOMPLETA"
  end
  for _, k in ipairs({"tempC", "coolant", "heated", "waste", "fuel", "damage", "burn", "actual", "maxBurn", "heating"}) do
    if not M.finite(d[k]) then return "LEITURA INVALIDA: " .. k end
  end
  for _, k in ipairs({"coolant", "heated", "waste", "fuel"}) do
    if d[k] < 0 or d[k] > 1 then return "NIVEL INVALIDO: " .. k end
  end
  if d.tempC < -273.15 or d.damage < 0 or d.damage > 100 or d.burn < 0 or d.actual < 0 or
    d.heating < 0 or d.maxBurn <= 0 or d.burn > d.maxBurn or d.actual > d.maxBurn then
    return "LEITURA FORA DA FAIXA"
  end
end
function M.hardFault(d)
  local why = M.valid(d)
  if why then return why end
  if d.damage > 0 then return "DANO NO REATOR" end
  if d.tempC >= C.maxTempC then return "TEMPERATURA ALTA" end
  if d.coolant < C.minCoolant then return "REFRIGERANTE INSUFICIENTE" end
  if d.heated >= C.maxHeated then return "REFRIGERANTE QUENTE ACUMULADO" end
  if d.waste >= C.maxWaste then return "RESIDUO ALTO" end
  if d.active and d.fuel < C.minFuel then return "COMBUSTIVEL INSUFICIENTE" end
end
function M.startFault(d)
  if d.tempC > C.startTempC then return "INICIO EXIGE TEMPERATURA <= 350 C" end
  if d.coolant < C.startCoolant then return "INICIO EXIGE REFRIGERANTE >= 50%" end
  if d.heated > C.startHeated then return "INICIO EXIGE QUENTE <= 50%" end
  if d.waste > C.startWaste then return "INICIO EXIGE RESIDUO <= 50%" end
  if d.fuel < C.startFuel then return "INICIO EXIGE COMBUSTIVEL >= 25%" end
end
-- Centered least squares avoids subtracting large epoch timestamps.
function M.regression(samples, field, span)
  local last = samples[#samples]
  if not last then return nil end
  local base = last.t - span
  local n, sx, sy, sxx, sxy, first = 0, 0, 0, 0, 0
  for _, s in ipairs(samples) do
    if s.t >= base - C.samplePeriod*2 then
      first = first or s.t
      local x, y = s.t - last.t, s[field]
      n, sx, sy, sxx, sxy = n+1, sx+x, sy+y, sxx+x*x, sxy+x*y
    end
  end
  if n < 3 or last.t-first < span-0.000001 then return nil end
  local den = n*sxx-sx*sx
  if den <= 0 then return nil end
  return (n*sxy-sx*sy)/den
end
local fields = {"tempC", "coolant", "heated", "waste", "fuel"}
local function slopes(samples, span)
  local result = {}
  for _, k in ipairs(fields) do result[k] = M.regression(samples, k, span) end
  return result
end
local function stable(s)
  return s.tempC and s.tempC <= C.maxTempSlope and s.coolant >= -C.maxTankSlope and
    s.heated <= C.maxTankSlope and s.waste <= C.maxTankSlope and s.fuel >= -C.maxTankSlope
end
local function predictive(d, s)
  if not s.tempC then return nil end
  for _, spec in ipairs({
    {"tempC", C.maxTempC, 1, 0.01}, {"coolant", C.minCoolant, -1, 0.000001},
    {"heated", C.maxHeated, 1, 0.000001}, {"waste", C.maxWaste, 1, 0.000001},
    {"fuel", C.minFuel, -1, 0.000001},
  }) do
    local k, limit, sign, noise = table.unpack(spec)
    if s[k] * sign > noise then
      local eta = (limit-d[k])/s[k]
      if eta >= 0 and eta <= C.predictSeconds then return "LIMITE PREVISTO: " .. k end
    end
  end
end
function M.validApproval(a, d, utc)
  if not (type(a) == "table" and a.policy == M.policy and a.phase == "APROVADO" and
    a.signature == d.signature and M.same(a.target, d.burn) and
    M.finite(a.finished) and utc >= a.finished and utc-a.finished < C.approvalTTL and
    M.finite(a.duration) and a.duration >= C.duration and M.finite(a.elapsed) and a.elapsed >= C.duration and
    M.finite(a.sampleCount) and a.sampleCount >= math.floor(C.duration / C.maxGap) and
    type(a.min) == "table" and type(a.max) == "table" and type(a.slopes) == "table") then return false end
  for _, k in ipairs(fields) do
    if not M.finite(a.min[k]) or not M.finite(a.max[k]) or not M.finite(a.slopes[k]) or
       a.min[k] > a.max[k] then return false end
  end
  return stable(a.slopes) and a.max.tempC < C.maxTempC and a.min.coolant >= C.minCoolant and
    a.max.heated < C.maxHeated and a.max.waste < C.maxWaste and a.min.fuel >= C.minFuel
end
function M.new(approvals)
  local self = {approvals = approvals or {}, samples = {}, guards = {}, phase = "AGUARDANDO"}
  function self:reset()
    self.samples, self.trial, self.target, self.signature, self.lastSample = {}, nil, nil, nil, nil
    self.ready, self.mismatch, self.long, self.short = nil, nil, {}, {}
    self.measureSamples, self.measureSampleAt, self.cached = {}, nil, nil
    self.phase = "AGUARDANDO"
  end
  function self:trip(reason, d, utc)
    if self.lock then return end
    self.lock = {reason = reason, utc = utc, data = d}
    self.approvals = {} -- A fault invalidates cached results for this installation.
    if self.trial and not self.trial.finished then
      self.trial.phase, self.trial.reason, self.trial.finished = "INTERROMPIDO", reason, utc
      self.result = self.trial
    end
    self.phase = "BLOQUEADO"
  end
  function self:step(d, now, utc)
    if self.lastUTC and (utc-self.lastUTC > C.maxGap*1000 or utc < self.lastUTC or
       now-self.lastTime > C.maxGap or now < self.lastTime) then
      self:trip("INTERVALO SEM LEITURAS CONFIAVEIS", d, utc)
    end
    self.lastUTC, self.lastTime = utc, now
    local fault = M.hardFault(d)
    if fault then self:trip(fault, d, utc) end
    if self.lock then return end
    if not d.active then
      if self.trial and not self.trial.finished then
        self.trial.phase, self.trial.reason, self.trial.finished = "INCONCLUSIVO", "REATOR DESLIGADO", utc
        self.result = self.trial
      end
      self:reset()
      self.guards, self.guardAt = {}, nil
      return
    end
    if d.burn <= 0 then self:trip("QUEIMA ZERO COM REATOR ATIVO", d, utc) return end
    if self.signature and self.signature ~= d.signature then
      self:trip("CONFIGURACAO DO REATOR MUDOU", d, utc) return
    end
    -- Protection trends survive rate changes and manual retests. Repeatedly
    -- selecting a new target cannot erase evidence of a failing cooling loop.
    if not self.guardAt or now-self.guardAt >= C.samplePeriod then
      local sample = {t = now}
      for _, k in ipairs(fields) do sample[k] = d[k] end
      self.guards[#self.guards+1], self.guardAt = sample, now
      while #self.guards > 65 do table.remove(self.guards, 1) end
      self.guardShort, self.guardLong = slopes(self.guards, 10), slopes(self.guards, 60)
    end
    local prediction = predictive(d, self.guardShort or {})
    if prediction then self:trip(prediction, d, utc) return end
    local protection = self.guardLong or {}
    if protection.tempC then
      if protection.coolant < -0.000002 then self:trip("RESERVA DE REFRIGERANTE DIMINUINDO", d, utc) return end
      if protection.heated > 0.000002 then self:trip("SAIDA DE REFRIGERANTE INSUFICIENTE", d, utc) return end
      if protection.waste > 0.000002 then self:trip("EXTRACAO DE RESIDUO INSUFICIENTE", d, utc) return end
    end
    if not self.target or not M.same(self.target, d.burn) then
      if self.trial and not self.trial.finished then
        self.trial.phase, self.trial.reason, self.trial.finished = "INCONCLUSIVO", "TAXA ALTERADA", utc
        self.result = self.trial
      end
      self:reset()
      local start = M.startFault(d)
      if start then self:trip(start, d, utc) return end
      self.target, self.signature = d.burn, d.signature
      local cached = self.approvals[M.key(d.burn, d.signature)]
      self.cached = M.validApproval(cached, d, utc) and cached or nil
      self.trial = {phase = "ESTABILIZANDO", target = d.burn, signature = d.signature,
        policy = M.policy, started = utc, elapsed = 0, duration = C.duration, settle = 0}
      self.began = now
    end
    if self.cached and not M.validApproval(self.cached, d, utc) then
      self:reset() -- Expiry forces a full fresh test on next sample.
      return
    end
    if not M.same(d.actual, d.burn) then
      self.mismatch = self.mismatch or now
      self.ready = nil
      if self.phase == "MEDINDO" or self.phase == "APROVADO" or now-self.mismatch >= 5 then
        self:trip("QUEIMA REAL DIFERENTE DA CONFIGURADA", d, utc)
      end
      return
    end
    self.mismatch = nil
    if not self.lastSample or now-self.lastSample >= C.samplePeriod then
      local sample = {t = now}
      for _, k in ipairs(fields) do sample[k] = d[k] end
      self.samples[#self.samples+1], self.lastSample = sample, now
      while #self.samples > C.duration + C.stabilize + 5 do table.remove(self.samples, 1) end
      self.short, self.long = slopes(self.samples, 10), slopes(self.samples, 60)
    end
    local l = self.long
    if self.phase == "APROVADO" then
      if not stable(l) then self:trip("CONDICOES DA APROVACAO PIORARAM", d, utc) end
      return
    end
    if now-self.began >= C.timeout then self:trip("TESTE INCONCLUSIVO: SEM ESTABILIDADE", d, utc) return end
    local t = self.trial
    if self.phase ~= "MEDINDO" then
      self.phase = self.cached and "REVALIDANDO" or "ESTABILIZANDO"
      if stable(l) and stable(self.short) then self.ready = self.ready or now else self.ready = nil end
      t.settle = self.ready and now-self.ready or 0
      if t.settle < C.stabilize then t.phase = self.phase return end
      if self.cached then
        self.phase, t.phase, t.elapsed, t.finished = "APROVADO", "APROVADO", C.duration, utc
        t.reason = "REFERENCIA RECENTE RECONFERIDA"
        return
      end
      self.phase, t.phase, self.measureAt = "MEDINDO", "MEDINDO", now
      t.initial, t.min, t.max = {}, {}, {}
      self.measureSamples = {}
      for _, k in ipairs(fields) do t.initial[k], t.min[k], t.max[k] = d[k], d[k], d[k] end
    end
    t.elapsed = math.min(C.duration, now-self.measureAt)
    -- Peripheral calls yield in the game, so the final poll rarely lands on
    -- the sampling cadence. Include that endpoint before requiring a full span.
    if not self.measureSampleAt or now-self.measureSampleAt >= C.samplePeriod or t.elapsed >= C.duration then
      local s = {t = now}
      for _, k in ipairs(fields) do s[k] = d[k] end
      self.measureSamples[#self.measureSamples+1], self.measureSampleAt = s, now
    end
    for _, k in ipairs(fields) do
      t.min[k], t.max[k] = math.min(t.min[k], d[k]), math.max(t.max[k], d[k])
    end
    t.minTemp, t.maxTemp, t.minCoolant = t.min.tempC, t.max.tempC, t.min.coolant
    t.maxHeated, t.maxWaste, t.minFuel = t.max.heated, t.max.waste, t.min.fuel
    if t.max.tempC-t.min.tempC > C.maxTempRange then
      self:trip("TESTE: TEMPERATURA NAO ESTABILIZOU", d, utc) return
    end
    if t.initial.coolant-t.min.coolant > C.maxTankDrift or
       t.max.heated-t.initial.heated > C.maxTankDrift or
       t.max.waste-t.initial.waste > C.maxTankDrift or
       t.initial.fuel-t.min.fuel > C.maxTankDrift then
      self:trip("TESTE: RESERVAS NAO SUSTENTAVEIS", d, utc) return
    end
    if t.elapsed >= C.duration then
      t.slopes = slopes(self.measureSamples, C.duration)
      t.sampleCount = #self.measureSamples
      if not stable(t.slopes) or not stable(l) or not stable(self.short) then
        self:trip("TESTE INCONCLUSIVO: TENDENCIA DESFAVORAVEL", d, utc) return
      end
      t.phase, t.reason, t.finished = "APROVADO", "ESTAVEL NAS CONDICOES OBSERVADAS", utc
      self.approvals[M.key(t.target, t.signature)], self.result, self.cached = t, t, t
      self.phase = "APROVADO"
    end
  end
  self:reset()
  return self
end
return M
