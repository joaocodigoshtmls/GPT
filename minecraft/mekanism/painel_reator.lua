-- Painel Reator v1.0 | CC:Tweaked / Mekanism
-- Apenas recebe e exibe dados. NUNCA comanda o reator.
local CHANNEL = 42
local TIMEOUT = 5
local modem = peripheral.find("modem")
if not modem then error("Sem modem neste computador.", 0) end
modem.open(CHANNEL)

local last, lastAt = nil, nil
local monitor = peripheral.find("monitor")

local function line(out, value)
  out.write(value)
  local _, y = out.getCursorPos()
  out.setCursorPos(1, y + 1)
end

local function draw(out)
  out.setBackgroundColor(colors.black)
  out.setTextColor(colors.white)
  out.clear()
  out.setCursorPos(1, 1)
  line(out, "=== PAINEL DO REATOR ===")
  if not last or not lastAt or os.clock() - lastAt > TIMEOUT then
    out.setTextColor(colors.orange)
    line(out, "SEM SINAL DO REATOR")
    out.setTextColor(colors.white)
    line(out, "Verifique modem e computador 1.")
    line(out, "Canal: 42")
    return
  end
  local d = last.data
  out.setTextColor(last.reason and colors.red or colors.lime)
  line(out, tostring(last.state or "SEM ESTADO"))
  out.setTextColor(colors.white)
  if d then
    line(out, "Reator: " .. (d.active and "LIGADO" or "DESLIGADO"))
    line(out, string.format("Queima: %.2f mB/t", d.burn))
    line(out, string.format("Temp: %.2f C", d.tempC))
    line(out, string.format("Sodio: %.1f%%", 100 * d.coolant))
    line(out, string.format("Sodio quente: %.1f%%", 100 * d.heated))
    line(out, string.format("Residuo: %.1f%%", 100 * d.waste))
    line(out, string.format("Dano: %.2f%%", d.damage))
    line(out, string.format("Heating: %.0f mB/t", d.heating))
  else
    line(out, "Falha na leitura do reator.")
  end
  if last.reason then
    out.setTextColor(colors.red)
    line(out, "ALARME: " .. tostring(last.reason))
    if not last.scramConfirmed then
      line(out, "ATENCAO: SCRAM NAO CONFIRMADO")
    end
  end
end

local function redraw()
  draw(term)
  if monitor then draw(monitor) end
end

if monitor then pcall(function() monitor.setTextScale(0.5) end) end
redraw()
local timer = os.startTimer(1)
while true do
  local ev, a, b, c, d = os.pullEvent()
  if ev == "modem_message" then
    local channel, msg = b, d
    if channel == CHANNEL and type(msg) == "table"
      and msg.kind == "mek_fission_telemetry_v1" then
      last, lastAt = msg, os.clock()
      redraw()
    end
  elseif ev == "timer" and a == timer then
    redraw()
    timer = os.startTimer(1)
  end
end
