-- Automatic fission supervision, Mekanism 10.4 / CC:Tweaked (Minecraft 1.20.1).
-- Never activates the reactor or changes burn rate. Read README before use.
local DIR = fs.getDir(shell.getRunningProgram())
local DB, LOCK, RESULTS = "/reator_auto_v2.json", "/reator_scram.json", "/reator_testes_v2.jsonl"
local CHANNEL = 42
local r, reactorName, engine, Core, data
local signature, signatureAt, lastRead, confirmed, diskError, uiError
local sequence, lastPublish, lastLockSave, lastResult = 0, -math.huge, -math.huge, nil
local startupFault, binding, epoch = nil, nil, tostring(os.epoch("utc"))
local savedLock
local function transmit(packet)
  -- A wired modem to the reactor may be enumerated before the radio outside.
  -- Send on every visible modem; failure of one must not suppress the others.
  local ok, modems = pcall(function() return {peripheral.find("modem")} end)
  if ok then
    for _, m in ipairs(modems) do pcall(m.transmit, CHANNEL, CHANNEL, packet) end
  end
end
local function candidates()
  local found = {}
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if p and type(p.scram) == "function" and type(p.getBurnRate) == "function" and
       type(p.getCoolantFilledPercentage) == "function" then found[#found+1] = name end
  end
  return found
end
local function stop(p)
  if not p then return false end
  local ok, active = pcall(p.getStatus)
  if not ok or active ~= false then pcall(p.scram) end
  ok, active = pcall(p.getStatus)
  return ok and active == false
end
local function emergencyStop()
  if r then return stop(r) end
  if reactorName then
    local ok, p = pcall(peripheral.wrap, reactorName)
    return ok and p and stop(p) or false
  end
  local ok, names = pcall(candidates)
  if not ok or #names == 0 then return false end
  local all = true
  for _, name in ipairs(names) do
    local success, stopped = pcall(function() return stop(peripheral.wrap(name)) end)
    if not success or not stopped then all = false end
  end
  return all
end
local function readJSON(path)
  assert(fs.getSize(path) <= 512000, "Arquivo grande demais: " .. path)
  local f = assert(fs.open(path, "r"), "Nao abriu " .. path)
  local raw = f.readAll()
  f.close()
  local value = textutils.unserializeJSON(raw)
  assert(type(value) == "table", "JSON invalido: " .. path)
  return value
end
local function atomicJSON(path, value)
  local raw = textutils.serializeJSON(value)
  local f = assert(fs.open(path .. ".tmp", "w"))
  f.write(raw)
  f.close()
  -- A .pending marker makes an interrupted replace a startup fault.
  local pending = assert(fs.open(path .. ".pending", "w"))
  pending.write("pending")
  pending.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(path .. ".tmp", path)
  fs.delete(path .. ".pending")
end
local function appendResult(value)
  if fs.exists(RESULTS) and fs.getSize(RESULTS) > 512000 then
    if fs.exists(RESULTS .. ".old") then fs.delete(RESULTS .. ".old") end
    fs.move(RESULTS, RESULTS .. ".old")
  end
  local f = assert(fs.open(RESULTS, "a"))
  f.writeLine(textutils.serializeJSON(value))
  f.close()
end
local function saveDB()
  local approvals, count = {}, 0
  for k, a in pairs(engine.approvals) do
    if type(a) == "table" and Core.finite(a.finished) and
       os.epoch("utc")-a.finished < Core.cfg.approvalTTL then
      count = count+1
      if count <= 128 then approvals[k] = a end
    end
  end
  atomicJSON(DB, {schema = 2, policy = Core.policy, reactor = reactorName, approvals = approvals})
end
local function trip(why, readings)
  if engine then engine:trip(why, readings or data, os.epoch("utc")) end
  confirmed = emergencyStop() -- Always stop BEFORE disk, screen or network work.
end
local function number(method, positive)
  assert(type(r[method]) == "function", "Metodo ausente: " .. method)
  local x = r[method]()
  assert(Core.finite(x) and x >= 0 and (not positive or x > 0), "Leitura invalida: " .. method)
  return x
end
local function fingerprint(now)
  local coolant = r.getCoolant()
  assert(type(coolant) == "table" and type(coolant.name) == "string", "Tipo de refrigerante indisponivel")
  local parts = {Core.policy, reactorName, coolant.name}
  local configKeys = {}
  for key in pairs(Core.cfg) do configKeys[#configKeys+1] = key end
  table.sort(configKeys)
  for _, key in ipairs(configKeys) do parts[#parts+1] = key .. "=" .. tostring(Core.cfg[key]) end
  for _, method in ipairs({"getCoolantCapacity", "getHeatedCoolantCapacity", "getWasteCapacity",
    "getFuelCapacity", "getFuelAssemblies", "getFuelSurfaceArea", "getHeatCapacity", "getMaxBurnRate"}) do
    parts[#parts+1] = string.format("%.17g", number(method, true))
  end
  signature, signatureAt = table.concat(parts, "|"), now
end
local function snapshot()
  local start, wall = os.clock(), os.epoch("utc")
  assert(peripheral.isPresent(reactorName), "Adaptador desconectado")
  local d = {active = r.getStatus(), burn = number("getBurnRate")}
  d.tempC = number("getTemperature")-273.15
  d.damage = number("getDamagePercent")
  -- Abort early on hard limits rather than waiting for the remaining calls.
  if d.damage > 0 then trip("DANO NO REATOR", d) end
  if d.tempC >= Core.cfg.maxTempC then trip("TEMPERATURA ALTA", d) end
  d.coolant = number("getCoolantFilledPercentage")
  assert(d.coolant <= 1, "REFRIGERANTE FORA DA FAIXA")
  if d.coolant < Core.cfg.minCoolant then trip("REFRIGERANTE INSUFICIENTE", d) end
  d.heated, d.waste = number("getHeatedCoolantFilledPercentage"), number("getWasteFilledPercentage")
  if d.heated >= Core.cfg.maxHeated then trip("REFRIGERANTE QUENTE ACUMULADO", d) end
  if d.waste >= Core.cfg.maxWaste then trip("RESIDUO ALTO", d) end
  d.fuel, d.actual = number("getFuelFilledPercentage"), number("getActualBurnRate")
  d.heating, d.maxBurn = number("getHeatingRate"), number("getMaxBurnRate", true)
  if not signatureAt or start-signatureAt >= 5 then fingerprint(start) end
  d.signature = signature
  local finalActive = r.getStatus()
  assert((d.active == finalActive or engine.lock) and Core.same(d.burn, number("getBurnRate")), "Estado mudou durante a leitura")
  d.active = finalActive
  d.readSeconds = os.clock()-start
  assert(d.readSeconds <= Core.cfg.maxGap and os.epoch("utc")-wall <= Core.cfg.maxGap*1000, "Leitura demorou demais")
  local why = Core.valid(d)
  assert(not why, why)
  return d
end
local function bind()
  local names = candidates()
  local configured = settings.get("reator.adapter") or binding
  if configured then
    assert(type(configured) == "string" and peripheral.isPresent(configured), "Adaptador configurado ausente")
    for _, name in ipairs(names) do
      if name == configured then reactorName, r = name, peripheral.wrap(name) return end
    end
    error("Adaptador configurado incompativel", 0)
  end
  assert(#names == 1, "Configure settings reator.adapter: nenhum ou varios reatores")
  reactorName, r = names[1], peripheral.wrap(names[1])
end
local function boot()
  -- Stop first, even if the module/database is missing or corrupt.
  confirmed = emergencyStop()
  Core = dofile(fs.combine(DIR, "reator_core.lua"))
  local approvals = {}
  if fs.exists(DB .. ".pending") or fs.exists(LOCK .. ".pending") then startupFault = "GRAVACAO INTERROMPIDA" end
  if fs.exists(DB) then
    local ok, db = pcall(readJSON, DB)
    if ok and db.schema == 2 and type(db.reactor) == "string" and type(db.approvals) == "table" then
      binding = db.reactor
      if db.policy == Core.policy then approvals = db.approvals end
    else startupFault = "HISTORICO ILEGIVEL" end
  end
  engine = Core.new(approvals)
  bind()
  local reason = startupFault or "INICIALIZACAO: REVISE E PRESSIONE U COM REATOR DESLIGADO"
  if fs.exists(LOCK) then
    local ok, old = pcall(readJSON, LOCK)
    reason = ok and type(old.reason) == "string" and old.reason or "BLOQUEIO ILEGIVEL"
  end
  -- Clean startup requires manual release but preserves recent references.
  -- A previous fault or corrupt storage invalidates them.
  if fs.exists(LOCK) or startupFault then engine.approvals = {} end
  engine.lock, engine.phase = {reason = reason, utc = os.epoch("utc")}, "BLOQUEADO"
  confirmed = emergencyStop()
end
local function estimates()
  local s, d, eta = engine.guardShort or engine.short or {}, data, {}
  if not d then return eta end
  for _, spec in ipairs({{"coolant", Core.cfg.minCoolant, -1}, {"heated", Core.cfg.maxHeated, 1},
    {"waste", Core.cfg.maxWaste, 1}, {"fuel", Core.cfg.minFuel, -1}, {"tempC", Core.cfg.maxTempC, 1}}) do
    local key, limit, sign = table.unpack(spec)
    if s[key] and s[key]*sign > 0 then eta[key] = math.max(0, (limit-d[key])/s[key]) end
  end
  return eta
end
local function publish(now)
  local t, s = engine.trial, (engine.lock and engine.guardLong or engine.long) or {}
  sequence = sequence+1
  local packet = {kind = "mek_fission_telemetry_v2", edition = "auto-v2.3", source = os.getComputerID(),
    session = epoch, sequence = sequence, utc = os.epoch("utc"), reactor = reactorName,
    mode = "auto", state = engine.phase, reason = engine.lock and engine.lock.reason,
    scramConfirmed = confirmed, data = data, trial = t, diskError = diskError, uiError = uiError,
    duration = Core.cfg.duration, stabilize = Core.cfg.stabilize,
    trend = {temp = s.tempC and s.tempC*60, sodium = s.coolant and s.coolant*6000,
      heated = s.heated and s.heated*6000, waste = s.waste and s.waste*6000, fuel = s.fuel and s.fuel*6000},
    eta = estimates(), readSeconds = lastRead, sampleCount = #engine.samples,
    warning = "VALIDACAO LOCAL E TEMPORARIA; MONITORAMENTO CONTINUA"}
  local ok, err = pcall(function()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("BASTIAO DE ACO | AUTO V2")
    print(engine.phase .. " | " .. reactorName)
    if data then
      print(string.format("Alvo %.6g | Real %.6g mB/t", data.burn, data.actual))
      print(string.format("%.2f C | Frio %.3f%%", data.tempC, data.coolant*100))
      print(string.format("Quente %.3f%% | Residuo %.3f%%", data.heated*100, data.waste*100))
    end
    if t then print(string.format("Estabiliza %.0f/%ds | Teste %.0f/%ds", t.settle or 0, Core.cfg.stabilize, t.elapsed, Core.cfg.duration)) end
    if engine.lock then
      term.setTextColor(colors.red)
      print(engine.lock.reason)
      print(confirmed and "DESLIGAMENTO CONFIRMADO" or "SCRAM NAO CONFIRMADO")
      print("U: liberar desligado, apos corrigir causa")
    end
    print("S: SCRAM | R: invalidar taxa e retestar")
    if diskError then print(diskError) end
  end)
  uiError = not ok and tostring(err) or nil -- UI failure cannot terminate supervision.
  transmit(packet)
  lastPublish = now
end
local function poll()
  if not peripheral.isPresent(reactorName) then r = nil end
  if not r and peripheral.isPresent(reactorName) then
    r, signatureAt = peripheral.wrap(reactorName), nil
  end
  local ok, result = pcall(snapshot)
  data = ok and result or nil
  local now, utc = os.clock(), os.epoch("utc")
  if not ok then trip("FALHA DE LEITURA: " .. tostring(result))
  else
    lastRead = data.readSeconds
    engine:step(data, now, utc)
  end
  if engine.lock then
    confirmed = emergencyStop()
    if savedLock ~= engine.lock and now-lastLockSave >= 5 then
      local saved = pcall(atomicJSON, LOCK, engine.lock)
      local dbSaved = not startupFault and pcall(saveDB)
      diskError = not (saved and dbSaved) and "FALHA AO SALVAR BLOQUEIO/HISTORICO" or nil
      if saved and dbSaved then savedLock = engine.lock end
      lastLockSave = now
    end
  end
  -- Interrupted tests need a log too. SCRAM above always precedes disk I/O.
  if engine.result and engine.result ~= lastResult then
    local saved = engine.lock ~= nil or pcall(saveDB)
    local logged = pcall(appendResult, engine.result)
    lastResult = engine.result
    if not saved or not logged then diskError = "FALHA AO SALVAR TESTE" trip(diskError) end
  end
  if now-lastPublish >= 1 then publish(now) end
end
local function release()
  if not engine.lock then return end
  local ok, fresh = pcall(snapshot)
  if not ok or fresh.active or Core.hardFault(fresh) or Core.startFault(fresh) then return end
  -- Never silently discard an unreadable database or interrupted transaction.
  if startupFault then uiError = "Corrija o arquivo indicado no README antes de liberar" return end
  local saved = pcall(function()
    saveDB()
    if fs.exists(LOCK .. ".pending") then fs.delete(LOCK .. ".pending") end
    if fs.exists(LOCK) then fs.delete(LOCK) end
  end)
  if not saved then diskError = "FALHA AO LIBERAR BLOQUEIO" return end
  engine.lock, confirmed, diskError = nil, nil, nil
  engine:reset()
  engine.lastUTC, engine.lastTime = nil, nil
  signatureAt = nil
  data = fresh
  poll()
end
local function run()
  boot()
  poll()
  local timer = os.startTimer(Core.cfg.period)
  while true do
    local event, id = os.pullEventRaw()
    local handled = true
    if event == "timer" and id == timer then
      poll()
    elseif event == "terminate" then
      trip("ENCERRAMENTO SOLICITADO (CTRL+T)")
      poll() -- Keep enforcing SCRAM; do not exit while status cannot be confirmed.
    elseif event == "key" and id == keys.s then
      trip("SCRAM MANUAL")
      poll()
    elseif event == "key" and id == keys.u then
      release()
    elseif event == "key" and id == keys.r and not engine.lock then
      engine.approvals = {}
      engine:reset()
      local ok = pcall(saveDB)
      if not ok then trip("FALHA AO INVALIDAR REFERENCIAS") end
      poll()
    elseif event == "peripheral_detach" and id == reactorName then
      trip("ADAPTADOR DESCONECTADO")
      poll()
    else
      handled = false
    end
    if handled then
      -- Peripheral calls yield and may consume the old timer while waiting.
      -- Every action that can read/control the reactor must rearm polling,
      -- including a denied U. Unrelated events must not postpone protection.
      os.cancelTimer(timer)
      timer = os.startTimer(Core.cfg.period)
    end
  end
end
local ok, err = xpcall(run, function(e) return tostring(e) end)
if not ok then
  -- Retry stopping the bound reactor, even when the main loop/module failed.
  while true do
    confirmed = emergencyStop()
    pcall(atomicJSON, LOCK, {reason = "ERRO INTERNO: " .. err, utc = os.epoch("utc")})
    -- Keep the original failure available locally and in passive diagnostics,
    -- even if the core could not load. Never send a stale sensor snapshot.
    pcall(function()
      local f = assert(fs.open("/reator_erro.txt", "w"))
      f.write("ERRO INTERNO: " .. err .. "\n_HOST: " .. tostring(_HOST) ..
        "\nAdaptador: " .. tostring(reactorName) .. "\nUTC: " .. os.epoch("utc"))
      f.close()
    end)
    pcall(function()
      sequence = sequence+1
      transmit({kind = "mek_fission_telemetry_v2", edition = "auto-v2.3",
        source = os.getComputerID(), session = epoch, sequence = sequence, utc = os.epoch("utc"),
        reactor = reactorName, mode = "auto", state = "BLOQUEADO", reason = "ERRO INTERNO: " .. err,
        scramConfirmed = confirmed, duration = 600, stabilize = 120})
    end)
    pcall(function()
      term.setTextColor(colors.red)
      print("ERRO INTERNO: " .. err)
      print(confirmed and "SCRAM CONFIRMADO; REINICIE PARA REVISAR" or "SCRAM NAO CONFIRMADO; INTERVENHA NO JOGO")
    end)
    local timer = os.startTimer(1)
    repeat local e, id = os.pullEventRaw() until e == "timer" and id == timer
  end
end
