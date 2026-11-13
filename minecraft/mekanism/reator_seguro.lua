-- Bastiao de Aco | Mekanism 10.4 / CC:Tweaked
-- reator_seguro teste 0.5 sem  |  reator_seguro normal
local CFG = {
  maxTempC = 450,
  minCoolant = 0.10,
  maxHeated = 0.90,
  maxWaste = 0.85,
  period = 0.25,
  channel = 42
}

local function findReactor()
  local p = peripheral.find("fissionReactorLogicAdapter")
  if p then return p end
  for _, name in ipairs(peripheral.getNames()) do
    local dev = peripheral.wrap(name)
    if dev and type(dev.getTemperature) == "function"
      and type(dev.getCoolantFilledPercentage) == "function"
      and type(dev.scram) == "function" then
      return dev
    end
  end
  return nil
end

local r
local function validNumber(x, label)
  if type(x) ~= "number" or x ~= x or x < 0 or x == math.huge then
    error("Leitura invalida: " .. label, 0)
  end
  return x
end

local function read()
  local d = {}
  d.active = r.getStatus()
  if type(d.active) ~= "boolean" then error("Status invalido", 0) end
  d.tempC = validNumber(r.getTemperature(), "temperatura") - 273.15
  d.coolant = validNumber(r.getCoolantFilledPercentage(), "sodio")
  d.heated = validNumber(r.getHeatedCoolantFilledPercentage(), "sodio quente")
  d.waste = validNumber(r.getWasteFilledPercentage(), "residuo")
  d.damage = validNumber(r.getDamagePercent(), "dano")
  d.burn = validNumber(r.getBurnRate(), "queima")
  d.actual = validNumber(r.getActualBurnRate(), "queima real")
  d.fuel = validNumber(r.getFuelFilledPercentage(), "combustivel")
  d.heating = validNumber(r.getHeatingRate(), "aquecimento")
  for _, k in ipairs({"coolant", "heated", "waste", "fuel"}) do
    if d[k] < 0 or d[k] > 1 then error("Nivel invalido: " .. k, 0) end
  end
  return d
end

local function reason(d)
  if d.damage > 0 then return "DANO NO REATOR" end
  if d.tempC >= CFG.maxTempC then return "TEMPERATURA ALTA" end
  if d.coolant < CFG.minCoolant then return "SODIO INSUFICIENTE" end
  if d.heated >= CFG.maxHeated then return "SODIO QUENTE ACUMULADO" end
  if d.waste >= CFG.maxWaste then return "RESIDUO NUCLEAR ALTO" end
  return nil
end

local mode, rateArg, supply = ...
mode = mode or "normal"
local target = tonumber((tostring(rateArg):gsub(",", ".")))
if mode ~= "normal" and mode ~= "teste" or
   mode == "teste" and (not target or target <= 0 or target >= math.huge or
   (supply ~= "com" and supply ~= "sem")) then
  error("Uso: reator_seguro normal | reator_seguro teste 0.5 com/sem", 0)
end

local LOCK = "/reator_scram.json"
local RESULTS = "/reator_testes.jsonl"
local function writeRecord(path, record, append)
  local json = textutils.serializeJSON(record)
  local f = assert(fs.open(path, append and "a" or "w"))
  f.writeLine(json)
  f.close()
end

local function readLock()
  if not fs.exists(LOCK) then return nil end
  local f = assert(fs.open(LOCK, "r"))
  local raw = f.readAll()
  f.close()
  local entry = textutils.unserializeJSON(raw)
  assert(type(entry) == "table" and type(entry.reason) == "string")
  return entry
end

local function lastApproval()
  local f = fs.open(RESULTS, "r")
  if not f then return nil end
  local last
  while true do
    local line = f.readLine()
    if not line then break end
    local ok, t = pcall(textutils.unserializeJSON, line)
    if ok and type(t) == "table" and t.phase == "APROVADO" and
       type(t.target) == "number" and (t.supply == "sem" or t.supply == "com") then
      last = t
    end
  end
  f.close()
  return last
end

local okLock, lock = pcall(readLock)
if not okLock then lock = {reason = "REGISTRO DE SCRAM ILEGIVEL"} end
local okHistory, approved = pcall(lastApproval)
if not okHistory then approved = nil end
local diskError, saved = nil, true
local function logLine(line)
  local f = assert(fs.open("/reator_eventos.log", "a"))
  f.writeLine(line)
  f.close()
end

local function newTest()
  return {phase = "AGUARDANDO", target = target, supply = supply, elapsed = 0}
end

local test = mode == "teste" and newTest() or nil
local data, confirmed, warning, trend, modem
local window, previous = {}, nil
local function sameRate(a, b)
  return math.abs(a - b) < 0.000001
end

local function updateTrend(now)
  trend = nil
  if not data or not data.active then window = {} return end
  local sample = {time = now, temp = data.tempC, level = data.coolant}
  local tail = window[#window]
  if not tail or now - tail.time >= 1 then window[#window+1] = sample end
  while #window > 1 and window[2].time <= now - 30 do table.remove(window, 1) end
  local base = window[1]
  if now - base.time >= 30 then
    trend = {temp = sample.temp - base.temp, sodium = (sample.level - base.level) * 100}
  end
end

local function trendAlert()
  if not trend then return nil end
  if trend.sodium <= -0.5 then return "QUEDA RAPIDA DO SODIO" end
  if trend.temp >= 5 then return "TEMPERATURA SUBINDO" end
end

local function finish(phase, why)
  test.phase, test.reason, test.finished = phase, why, os.epoch("utc")
  local ok = pcall(writeRecord, RESULTS, test, true)
  if not ok then diskError = "FALHA AO SALVAR RESULTADO" end
  if phase == "APROVADO" and ok then approved = test end
end

local function updateTest(now, gap)
  if not test or test.finished then return end
  if lock then finish("INTERROMPIDO", lock.reason) return end
  local matches = data.active and sameRate(data.burn, target) and sameRate(data.actual, target)
  if test.phase == "MEDINDO" then
    if gap then finish("INCONCLUSIVO", "INTERVALO SEM AMOSTRAS") return end
    if not matches then
      finish("INCONCLUSIVO", data.active and "QUEIMA MUDOU" or "REATOR DESLIGADO")
      return
    end
  elseif not matches or gap then
    test.readyAt, test.phase = nil, "AGUARDANDO"
    return
  else
    test.phase = "ESTABILIZANDO"
    test.readyAt = test.readyAt or now
    if trendAlert() then test.readyAt = now end
    if now - test.readyAt < 30 or not trend then return end
    test.phase, test.start = "MEDINDO", now
    test.minTemp, test.maxTemp = data.tempC, data.tempC
    test.initialCoolant, test.minCoolant = data.coolant, data.coolant
    test.maxWaste, test.maxHeated = data.waste, data.heated
    test.minFuel = data.fuel
  end
  test.elapsed = math.min(300, now - test.start)
  test.minTemp = math.min(test.minTemp, data.tempC)
  test.maxTemp = math.max(test.maxTemp, data.tempC)
  test.minCoolant = math.min(test.minCoolant, data.coolant)
  test.maxHeated = math.max(test.maxHeated, data.heated)
  test.maxWaste = math.max(test.maxWaste, data.waste)
  test.minFuel = math.min(test.minFuel, data.fuel)
  local why = trendAlert()
  if test.maxTemp - test.minTemp > 5 then why = why or "VARIACAO ACIMA DE 5 C" end
  if (test.initialCoolant - test.minCoolant) * 100 > 0.5 then why = why or "QUEDA ACIMA DE 0.5 PP" end
  if why then finish("INTERROMPIDO", why)
  elseif test.elapsed >= 300 then finish("APROVADO", "ESTAVEL " .. supply:upper() .. " REPOSICAO") end
end

local function enforce()
  if not r then return false end
  if not data or data.active then pcall(function() r.scram() end) end
  local ok, active = pcall(function() return r.getStatus() end)
  return ok and active == false
end

local function poll()
  local now = os.clock()
  local gap = previous and now - previous > 2
  previous = now
  if gap then window = {} end
  if not r then r = findReactor() end
  local ok, result = pcall(read)
  data = ok and result or nil
  local fault
  if ok then fault = reason(data) else fault = "FALHA DE LEITURA: " .. tostring(result) end
  if fault and not lock then
    lock = {reason = fault, utc = os.epoch("utc"), data = data}
    saved = false
  end
  if lock then
    confirmed = enforce()
    if not saved then
      saved = pcall(writeRecord, LOCK, lock, false)
      if saved then
        if not pcall(logLine, textutils.serializeJSON(lock)) then diskError = "FALHA NO LOG" end
      else diskError = "FALHA AO SALVAR BLOQUEIO" end
    end
  end
  if not ok then r = nil end
  updateTrend(now)
  updateTest(now, gap)
  warning = trendAlert()
  if data and data.fuel < 0.10 then warning = warning or "COMBUSTIVEL BAIXO" end
  if mode == "normal" and data then
    if not approved then warning = warning or "SEM TAXA VALIDADA"
    elseif not sameRate(data.burn, approved.target) then warning = warning or "FORA DA TAXA VALIDADA"
    elseif data.active and not sameRate(data.actual, data.burn) then warning = warning or "QUEIMA REAL ABAIXO DO ALVO" end
  end

  local packet = {kind = "mek_fission_telemetry_v1", edition = "bastiao", source = os.getComputerID(),
    mode = mode, state = lock and "BLOQUEADO" or "MONITORANDO", reason = lock and lock.reason,
    trip = lock, scramConfirmed = confirmed, data = data, trial = test, trend = trend,
    reference = approved and {target = approved.target, supply = approved.supply},
    warning = warning, diskError = diskError}
  if not modem then modem = peripheral.find("modem") end
  if modem and not pcall(modem.transmit, CFG.channel, CFG.channel, packet) then modem = nil end

  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.white)
  print("BASTIAO DE ACO | " .. mode:upper())
  if data then
    print(string.format("Config %.2f | Real %.2f mB/t", data.burn, data.actual))
    print(string.format("Temp %.2f C | Dano %.2f%%", data.tempC, data.damage))
    print(string.format("Sodio %.1f%% | Quente %.1f%%", 100*data.coolant, 100*data.heated))
    print(string.format("Residuo %.1f%% | Combustivel %.1f%%", 100*data.waste, 100*data.fuel))
    print(string.format("Aquecimento %.0f mB/t", data.heating))
  end
  if lock then
    term.setTextColor(colors.red)
    print(lock.reason)
    print(confirmed and "DESLIGAMENTO CONFIRMADO" or "SCRAM NAO CONFIRMADO")
    if lock.data then print(string.format("Sodio no disparo %.2f%%", 100*lock.data.coolant)) end
    print("U: liberar apos revisar a causa")
  else
    print(data and data.active and "REATOR LIGADO" or "REATOR DESLIGADO")
  end
  if test then
    print(string.format("%s  %d/300 s", test.phase, math.floor(test.elapsed)))
    if test.reason then print(test.reason) end
    if test.finished then print("R: repetir teste neste alvo") end
    if test.phase == "APROVADO" and approved == test then print("N: operacao normal") end
  end
  if warning then print(warning) end
  if diskError then print(diskError) end
  if not modem then print("SEM MODEM") end
end

local function release()
  if not lock then return end
  local ok, fresh = pcall(read)
  if not ok or fresh.active or reason(fresh) then return end
  if not pcall(logLine, "Liberacao manual UTC " .. os.epoch("utc")) then
    diskError = "FALHA NO LOG" return
  end
  if fs.exists(LOCK) and not pcall(fs.delete, LOCK) then diskError = "FALHA AO LIBERAR" return end
  lock, confirmed, saved, diskError = nil, nil, true, nil
end

poll()
local timer = os.startTimer(CFG.period)
while true do
  local event, id = os.pullEvent()
  if event == "timer" and id == timer then
    poll()
    timer = os.startTimer(CFG.period)
  elseif event == "key" and id == keys.u then
    release()
  elseif event == "key" and id == keys.n and test and test.phase == "APROVADO"
      and approved == test and not lock then
    mode, test = "normal", nil
  elseif event == "key" and id == keys.r and test and test.finished and not lock then
    test = newTest()
    window = {}
  end
end
