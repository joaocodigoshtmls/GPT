-- Reator Seguro v1.3 | Mekanism 1.20.1 / CC:Tweaked
-- Protecao local + telemetria pelo modem, canal 42.
-- NAO aceita comandos pela rede. NAO religa automaticamente.
-- Mantenha um Logic Adapter independente para SCRAM fisico.

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

local r = findReactor()
if not r then
  error("Logic Adapter nao encontrado; confira a conexao do computador.", 0)
end

local modem = peripheral.find("modem")
local locked, data, scramConfirmed = nil, nil, true
local scramError = nil

local function validNumber(x, label)
  if type(x) ~= "number" or x ~= x then
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
  d.heating = validNumber(r.getHeatingRate(), "aquecimento")
  for _, k in ipairs({"coolant", "heated", "waste"}) do
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

local function log(text)
  pcall(function()
    local f = fs.open("reator_eventos.log", "a")
    if f then
      f.writeLine("Dia " .. os.day() .. " " ..
        textutils.formatTime(os.time(), true) .. ": " .. tostring(text))
      f.close()
    end
  end)
end

local function shutdown()
  if data and not data.active then
    scramConfirmed, scramError = true, nil
    return
  end
  local ok, err = pcall(function() r.scram() end)
  if ok then
    scramConfirmed, scramError = true, nil
  else
    local statusOK, status = pcall(function() return r.getStatus() end)
    scramConfirmed = statusOK and status == false
    scramError = scramConfirmed and nil or tostring(err)
  end
end

local function transmit()
  if not modem then return end
  local packet = {
    kind = "mek_fission_telemetry_v1",
    source = os.getComputerID(),
    state = locked and "BLOQUEADO" or "MONITORANDO",
    reason = locked,
    scramConfirmed = scramConfirmed,
    error = scramError,
    data = data
  }
  pcall(function() modem.transmit(CFG.channel, CFG.channel, packet) end)
end

while true do
  local ok, result = pcall(read)
  if ok then
    data = result
    if not locked then
      locked = reason(data)
      if locked then log(locked) end
    end
  else
    data = nil
    if not locked then
      locked = "FALHA DE LEITURA: " .. tostring(result)
      log(locked)
    end
  end

  if locked then shutdown() end
  transmit()

  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("=== REATOR SEGURO v1.3 ===")
  if data then
    print("Estado: " .. (data.active and "LIGADO" or "DESLIGADO"))
    print(string.format("Queima: %.2f mB/t", data.burn))
    print(string.format("Aquecimento: %.0f mB/t", data.heating))
    print(string.format("Temperatura: %.2f C", data.tempC))
    print(string.format("Sodio: %.1f%%", 100 * data.coolant))
    print(string.format("Sodio quente: %.1f%%", 100 * data.heated))
    print(string.format("Residuo: %.1f%%", 100 * data.waste))
    print(string.format("Dano: %.2f%%", data.damage))
  else
    print("Leitura do reator indisponivel.")
  end
  if locked then
    term.setTextColor(colors.red)
    print("!!! SCRAM / BLOQUEADO !!!")
    print(locked)
    if not scramConfirmed then
      print("SCRAM NAO CONFIRMADO")
      print(tostring(scramError or "Verifique o reator"):sub(1,42))
    end
  else
    term.setTextColor(colors.lime)
    print("MONITORAMENTO ATIVO")
  end
  term.setTextColor(colors.white)
  print(modem and "Modem: transmitindo canal 42" or "SEM MODEM: rede indisponivel")
  sleep(CFG.period)
end
