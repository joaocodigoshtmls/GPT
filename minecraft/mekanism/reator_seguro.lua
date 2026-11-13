-- Reator Seguro v1.1 - Minecraft 1.20.1 / Mekanism 10.4 / CC:Tweaked
-- Monitor de seguranca. NUNCA liga o reator automaticamente.
-- Requer um Fission Reactor Logic Adapter conectado ao computador.
-- Use um Logic Adapter independente de seguranca como protecao adicional.

local CFG = {
  temp_max_c = 450,
  coolant_min = 0.25,
  heated_max = 0.90,
  waste_max = 0.85,
  interval = 0.2
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

local reactor = findReactor()
if not reactor then
  error("Reator nao encontrado. Verifique o Logic Adapter e o cabo/modem.", 0)
end

local function number(value, label)
  if type(value) ~= "number" or value ~= value then
    error("Leitura invalida: " .. label, 0)
  end
  return value
end

-- As porcentagens de enchimento do Mekanism variam de 0 a 1.
-- getDamagePercent() ja retorna a porcentagem, e nao uma fracao.
local function read()
  local d = {}
  d.on = reactor.getStatus()
  if type(d.on) ~= "boolean" then error("Status invalido", 0) end
  d.temp_c = number(reactor.getTemperature(), "temperatura") - 273.15
  d.coolant = number(reactor.getCoolantFilledPercentage(), "sodio")
  d.heated = number(reactor.getHeatedCoolantFilledPercentage(), "sodio quente")
  d.waste = number(reactor.getWasteFilledPercentage(), "residuo")
  d.damage = number(reactor.getDamagePercent(), "dano")
  d.burn = number(reactor.getBurnRate(), "burn rate")
  d.heating = number(reactor.getHeatingRate(), "heating rate")

  for _, key in ipairs({"coolant", "heated", "waste"}) do
    if d[key] < 0 or d[key] > 1 then
      error("Porcentagem fora da faixa: " .. key, 0)
    end
  end
  return d
end

local function unsafeReason(d)
  if d.damage > 0 then return "DANO NO REATOR" end
  if d.temp_c >= CFG.temp_max_c then return "TEMPERATURA ALTA" end
  if d.coolant < CFG.coolant_min then return "SODIO INSUFICIENTE" end
  if d.heated >= CFG.heated_max then return "SODIO QUENTE ACUMULADO" end
  if d.waste >= CFG.waste_max then return "RESIDUO NUCLEAR ALTO" end
  return nil
end

local function log(reason)
  local ok = pcall(function()
    local file = fs.open("reator_eventos.log", "a")
    if file then
      file.writeLine("Dia " .. tostring(os.day()) .. " " ..
        textutils.formatTime(os.time(), true) .. " | " .. tostring(reason))
      file.close()
    end
  end)
end

local locked, data, scramOK = nil, nil, true

while true do
  local ok, result = pcall(read)
  if ok then
    data = result
    if not locked then
      locked = unsafeReason(data)
      if locked then log(locked) end
    end
  else
    data = nil
    if not locked then
      locked = "FALHA DE LEITURA: " .. tostring(result)
      log(locked)
    end
  end

  if locked then
    scramOK = pcall(function() reactor.scram() end)
  end

  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("=== REATOR SEGURO v1.1 ===")

  if data then
    print("Estado: " .. (data.on and "LIGADO" or "DESLIGADO"))
    print(string.format("Queima: %.2f mB/t", data.burn))
    print(string.format("Aquecimento: %.0f mB/t", data.heating))
    print(string.format("Temperatura: %.2f C", data.temp_c))
    print(string.format("Sodio: %.1f%%", data.coolant * 100))
    print(string.format("Sodio quente: %.1f%%", data.heated * 100))
    print(string.format("Residuo: %.1f%%", data.waste * 100))
    print(string.format("Dano: %.2f%%", data.damage))
  else
    print("Falha ao consultar o reator.")
  end

  if locked then
    term.setTextColor(colors.red)
    print("!!! SCRAM / BLOQUEADO !!!")
    print(locked)
    if not scramOK then print("FALHA AO ENVIAR SCRAM!") end
    term.setTextColor(colors.white)
    print("Corrija a causa e reinicie o programa.")
  else
    term.setTextColor(colors.lime)
    print("MONITORAMENTO ATIVO")
    term.setTextColor(colors.white)
    print("Nao liga nem altera a queima.")
  end

  sleep(CFG.interval)
end
