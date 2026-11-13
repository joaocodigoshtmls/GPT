-- PAINEL DO REATOR v3.0
-- Mekanism 1.20.1 + CC:Tweaked | Apenas leitura, canal 42
-- Teste de 5 minutos: temperatura, sodio e tendencias em 30s.
-- Este painel nao envia comandos nem substitui o controlador de seguranca.

local CHANNEL = 42
local TEST_SECONDS = 300
local TIMEOUT = 5
local SCALE = 0.5

-- Alertas de tendencia do painel (nao sao limites de SCRAM).
local RAPID_COOLANT_DROP_PP = 0.5  -- pontos percentuais em ate 30 segundos
local RAPID_TEMP_RISE_C = 5        -- graus Celsius em ate 30 segundos
local MAX_STABLE_TEMP_RANGE_C = 5 -- variacao min/max ao longo dos 5 minutos
local MAX_STABLE_COOLANT_DROP_PP = 0.5

local modem = peripheral.find("modem")
if not modem then error("Modem nao encontrado neste computador.", 0) end
modem.open(CHANNEL)
local monitor = peripheral.find("monitor")
if monitor then monitor.setTextScale(SCALE) end

local latest, latestAt = nil, nil
local previousActive = false
local session = nil
local samples = {}
local lastSample = nil

local function clamp(n, lo, hi)
  return math.max(lo, math.min(hi, n))
end

local function num(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function formatTime(seconds)
  seconds = math.max(0, math.ceil(seconds))
  return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function pp(n)
  return string.format("%.2f pp", n)
end

local function pct(n)
  return string.format("%.1f%%", (n or 0) * 100)
end

local function signed(n, suffix)
  return string.format("%+.2f%s", n, suffix or "")
end

local function resetTest(d, now)
  if not d or not d.active then
    session = nil
    samples = {}
    lastSample = nil
    return
  end
  session = {
    state = "RUNNING",
    start = now,
    finish = nil,
    initialTemp = d.tempC,
    initialCoolant = d.coolant,
    minimumTemp = d.tempC,
    maximumTemp = d.tempC,
    minimumCoolant = d.coolant,
    maximumCoolant = d.coolant,
    fastCoolant = false,
    fastTemp = false,
    reason = nil
  }
  samples = {}
  lastSample = nil
end

local function recentTrend()
  if #samples < 2 then return nil end
  local first = samples[1]
  local last = samples[#samples]
  local span = last.t - first.t
  if span < 10 then return nil end
  return {
    span = span,
    temperature = last.temp - first.temp,
    coolantPP = (last.coolant - first.coolant) * 100
  }
end

local function acceptData(d, now)
  local valid = type(d) == "table" and
    type(d.active) == "boolean" and
    num(d.tempC) and num(d.coolant) and num(d.heated) and
    num(d.waste) and num(d.damage) and num(d.burn) and
    num(d.heating)

  if not valid then return end

  if d.active and not previousActive then
    resetTest(d, now)
  elseif not d.active and previousActive and
      session and session.state == "RUNNING" then
    session.state = "INTERRUPTED"
    session.reason = "Reator desligado antes do fim"
  end
  previousActive = d.active

  if d.active then
    if not lastSample or now - lastSample >= 1 then
      samples[#samples + 1] = {t = now, temp = d.tempC, coolant = d.coolant}
      lastSample = now
      while #samples > 2 and samples[1].t < now - 30 do
        table.remove(samples, 1)
      end
    end
    local trend = recentTrend()
    if session and session.state == "RUNNING" then
      session.minimumTemp = math.min(session.minimumTemp, d.tempC)
      session.maximumTemp = math.max(session.maximumTemp, d.tempC)
      session.minimumCoolant = math.min(session.minimumCoolant, d.coolant)
      session.maximumCoolant = math.max(session.maximumCoolant, d.coolant)
      if trend then
        if trend.coolantPP <= -RAPID_COOLANT_DROP_PP then
          session.fastCoolant = true
        end
        if trend.temperature >= RAPID_TEMP_RISE_C then
          session.fastTemp = true
        end
      end
      if now - session.start >= TEST_SECONDS then
        session.state = "DONE"
        session.finish = now
      end
    end
  else
    samples = {}
    lastSample = nil
  end
end

local function testSummary()
  if not session then return "AGUARDANDO REATOR", colors.lightGray end
  if session.state == "INTERRUPTED" then
    return "TESTE INTERROMPIDO", colors.orange
  end
  if session.state == "RUNNING" then
    return "TESTE EM ANDAMENTO", colors.cyan
  end
  local range = session.maximumTemp - session.minimumTemp
  local drop = math.max(0, (session.initialCoolant - session.minimumCoolant) * 100)
  if range <= MAX_STABLE_TEMP_RANGE_C and
     drop <= MAX_STABLE_COOLANT_DROP_PP and
     not session.fastCoolant and not session.fastTemp then
    return "ESTAVEL NOS 5 MIN", colors.lime
  end
  return "VARIACAO DETECTADA", colors.orange
end

local function safeLatest()
  if not latest or not latestAt or os.clock() - latestAt > TIMEOUT then
    return nil, "SEM SINAL", colors.orange
  end
  if latest.reason then return latest.data, "SCRAM / BLOQUEADO", colors.red end
  if not latest.data then return nil, "SEM DADOS", colors.orange end
  if latest.data.active then return latest.data, "REATOR LIGADO", colors.lime end
  return latest.data, "REATOR DESLIGADO", colors.lightGray
end

local function rect(out, x, y, width, height, bg)
  local w, h = out.getSize()
  local x1, y1 = math.max(1, x), math.max(1, y)
  local x2, y2 = math.min(w, x + width - 1), math.min(h, y + height - 1)
  if x1 > x2 or y1 > y2 then return end
  out.setBackgroundColor(bg)
  for row = y1, y2 do
    out.setCursorPos(x1, row)
    out.write(string.rep(" ", x2 - x1 + 1))
  end
end

local function write(out, x, y, str, fg, bg, limit)
  local w, h = out.getSize()
  if x > w or y > h or y < 1 then return end
  str = tostring(str or "")
  if x < 1 then
    str = str:sub(2 - x)
    x = 1
  end
  local available = math.min(w - x + 1, limit or w)
  if available < 1 then return end
  out.setBackgroundColor(bg or colors.black)
  out.setTextColor(fg or colors.white)
  out.setCursorPos(x, y)
  out.write(str:sub(1, available))
end

local function middle(out, x, y, width, str, fg, bg)
  str = tostring(str or "")
  str = str:sub(1, width)
  write(out, x + math.floor((width - #str) / 2), y, str, fg, bg, width)
end

local function bar(out, x, y, width, fraction, fg)
  if width <= 0 then return end
  fraction = clamp(tonumber(fraction) or 0, 0, 1)
  rect(out, x, y, width, 1, colors.gray)
  local filled = math.floor(width * fraction + 0.5)
  if filled > 0 then rect(out, x, y, filled, 1, fg) end
end

local function large(out, w, h, d, state, stateColor)
  local x, y = 2, 1
  local width = w - 2
  rect(out, x, y, width, h, colors.black)
  rect(out, x, 1, width, 3, colors.blue)
  middle(out, x, 2, width, "CENTRAL DE MONITORAMENTO | REATOR DE FISSAO", colors.white, colors.blue)
  middle(out, x, 4, width, state, stateColor, colors.black)

  local timeLeft = 300
  if session then
    if session.state == "DONE" then
      timeLeft = 0
    else
      timeLeft = TEST_SECONDS - (os.clock() - session.start)
    end
  end
  local labelTest, labelColor = testSummary()
  rect(out, x, 5, width, 5, colors.lightGray)
  middle(out, x, 5, width, "TESTE DE ESTABILIDADE | 5 MINUTOS", colors.black, colors.lightGray)
  middle(out, x, 6, width, formatTime(timeLeft), colors.blue, colors.lightGray)
  middle(out, x, 7, width, labelTest, labelColor, colors.lightGray)
  local progress = session and clamp((TEST_SECONDS - timeLeft) / TEST_SECONDS, 0, 1) or 0
  bar(out, x + 3, 9, width - 6, progress, colors.blue)

  local col = math.floor((width - 3) / 2)
  local lx = x + 1
  local rx = x + col + 2
  local rw = width - col - 3
  rect(out, lx, 11, col, 11, colors.gray)
  rect(out, rx, 11, rw, 11, colors.gray)
  write(out, lx + 2, 12, "OPERACAO", colors.cyan, colors.gray)
  middle(out, lx, 14, col, string.format("QUEIMA: %.2f mB/t", d and d.burn or 0), colors.white, colors.gray)
  middle(out, lx, 16, col, string.format("TEMP.: %.2f C", d and d.tempC or 0), colors.white, colors.gray)
  middle(out, lx, 18, col, string.format("DANO: %.2f%%", d and d.damage or 0), colors.white, colors.gray)
  middle(out, lx, 20, col, string.format("HEATING: %.0f mB/t", d and d.heating or 0), colors.white, colors.gray)

  write(out, rx + 2, 12, "FLUIDOS DO REATOR", colors.cyan, colors.gray)
  local bw = rw - 4
  local function gauge(ty, name, level, color)
    write(out, rx + 2, ty, name, colors.white, colors.gray, bw - 7)
    write(out, rx + rw - 8, ty, pct(level), colors.white, colors.gray, 7)
    bar(out, rx + 2, ty + 1, bw, level, color)
  end
  gauge(14, "SODIO", d and d.coolant or 0, colors.cyan)
  gauge(17, "SODIO QUENTE", d and d.heated or 0, colors.orange)
  gauge(20, "RESIDUOS", d and d.waste or 0, colors.purple)

  rect(out, x + 1, 23, width - 2, 5, colors.black)
  local baselineTemp = session and session.initialTemp
  local baselineCoolant = session and session.initialCoolant
  local trend = recentTrend()
  write(out, x + 2, 23, "ANALISE DOS ULTIMOS 30s / DESDE O INICIO", colors.cyan, colors.black)
  local tempDelta = d and baselineTemp and (d.tempC - baselineTemp) or 0
  local coolDelta = d and baselineCoolant and (d.coolant - baselineCoolant) * 100 or 0
  local t30 = trend and signed(trend.temperature, " C") or "calculando..."
  local c30 = trend and signed(trend.coolantPP, " pp") or "calculando..."
  write(out, x + 2, 24, "TEMP 30s: " .. t30 .. "  |  TOTAL: " .. signed(tempDelta, " C"), colors.white, colors.black, width - 4)
  write(out, x + 2, 25, "SODIO 30s: " .. c30 .. "  |  TOTAL: " .. signed(coolDelta, " pp"), colors.white, colors.black, width - 4)
  local alarm = ""
  if not d then alarm = "SEM TELEMETRIA DO REATOR"
  elseif latest and latest.reason then alarm = "ALARME: " .. tostring(latest.reason)
  elseif trend and trend.coolantPP <= -RAPID_COOLANT_DROP_PP then alarm = "ATENCAO: SODIO CAINDO RAPIDAMENTE"
  elseif trend and trend.temperature >= RAPID_TEMP_RISE_C then alarm = "ATENCAO: TEMPERATURA SUBINDO RAPIDAMENTE"
  elseif session and session.state == "DONE" then alarm = labelTest
  elseif session and session.state == "INTERRUPTED" then alarm = "TESTE INTERROMPIDO"
  else alarm = "MONITORAMENTO CONTINUO" end
  local alertColor = alarm:find("ATENCAO") or alarm:find("ALARME") and colors.red or colors.lime
  if alarm:find("ATENCAO") or alarm:find("ALARME") then alertColor = colors.red
  elseif not d or (session and session.state == "INTERRUPTED") then alertColor = colors.orange
  else alertColor = colors.lime end
  middle(out, x, 27, width, alarm, alertColor, colors.black)

  if h >= 30 then
    middle(out, x, h - 1, width, "R = REINICIAR TESTE  |  SOMENTE LEITURA  |  CANAL 42  |  v3.0", colors.lightGray, colors.black)
  end
end

local function small(out, w, h, d, state, stateColor)
  rect(out, 1, 1, w, 2, colors.blue)
  middle(out, 1, 1, w, "PAINEL REATOR v3.0", colors.white, colors.blue)
  middle(out, 1, 3, w, state, stateColor, colors.black)
  local left = session and TEST_SECONDS - (os.clock() - session.start) or TEST_SECONDS
  if session and session.state == "DONE" then left = 0 end
  local tlabel, tcolor = testSummary()
  middle(out, 1, 5, w, "TESTE 5 MIN: " .. formatTime(left), colors.yellow, colors.black)
  middle(out, 1, 6, w, tlabel, tcolor, colors.black)
  local items = {
    string.format("Queima: %.2f mB/t", d and d.burn or 0),
    string.format("Temp.: %.2f C", d and d.tempC or 0),
    "Sodio: " .. pct(d and d.coolant or 0),
    "Sodio quente: " .. pct(d and d.heated or 0),
    "Residuos: " .. pct(d and d.waste or 0),
    string.format("Dano: %.2f%%", d and d.damage or 0)
  }
  for i, item in ipairs(items) do
    if 7 + i < h - 2 then middle(out, 1, 7 + i, w, item, colors.white, colors.black) end
  end
  local tr = recentTrend()
  if h >= 17 then
    middle(out, 1, h - 4, w, tr and ("Temp/30s: " .. signed(tr.temperature, " C")) or "Temp/30s: calculando", colors.cyan, colors.black)
    middle(out, 1, h - 3, w, tr and ("Sodio/30s: " .. signed(tr.coolantPP, " pp")) or "Sodio/30s: calculando", colors.cyan, colors.black)
  end
  middle(out, 1, h - 1, w, "R = novo teste  |  canal 42", colors.lightGray, colors.black)
end

local function draw(out)
  local w, h = out.getSize()
  local d, state, stateColor = safeLatest()
  out.setBackgroundColor(colors.black)
  out.clear()
  if w >= 58 and h >= 29 then
    large(out, w, h, d, state, stateColor)
  else
    small(out, w, h, d, state, stateColor)
  end
end

local function redraw()
  draw(term)
  if monitor then draw(monitor) end
end

redraw()
local timer = os.startTimer(0.5)
while true do
  local event, a, b, c, d = os.pullEvent()
  if event == "modem_message" then
    local channel, message = b, d
    if channel == CHANNEL and type(message) == "table" and
       message.kind == "mek_fission_telemetry_v1" then
      latest, latestAt = message, os.clock()
      if message.data then acceptData(message.data, latestAt) end
      redraw()
    end
  elseif event == "timer" and a == timer then
    if session and session.state == "RUNNING" and
       (not latestAt or os.clock() - latestAt > TIMEOUT) then
      session.state = "INTERRUPTED"
      session.reason = "Sinal do computador perdido"
    end
    redraw()
    timer = os.startTimer(0.5)
  elseif event == "key" and a == keys.r then
    local current = safeLatest()
    resetTest(current, os.clock())
    redraw()
  elseif event == "monitor_resize" or event == "term_resize" then
    redraw()
  end
end
