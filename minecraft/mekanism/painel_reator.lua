-- Painel Reator v2.0 | CC:Tweaked + Mekanism 1.20.1
-- Interface centralizada, barras e alertas; SOMENTE LEITURA.
-- Recebe telemetria do Reator Seguro v1.3 pelo canal 42.

local CHANNEL = 42
local TIMEOUT = 5
local MONITOR_SCALE = 0.5

local modem = peripheral.find("modem")
if not modem then error("Nao encontrei modem neste computador.", 0) end
modem.open(CHANNEL)

local screen = peripheral.find("monitor")
if screen then screen.setTextScale(MONITOR_SCALE) end

local last, lastAt = nil, nil

local function clamp(x, a, b)
  return math.max(a, math.min(b, x))
end

local function rect(out, x, y, width, height, bg)
  local w, h = out.getSize()
  local x1, y1 = clamp(x, 1, w), clamp(y, 1, h)
  local x2, y2 = clamp(x + width - 1, 1, w), clamp(y + height - 1, 1, h)
  if width <= 0 or height <= 0 or x2 < x1 or y2 < y1 then return end
  out.setBackgroundColor(bg)
  for row = y1, y2 do
    out.setCursorPos(x1, row)
    out.write(string.rep(" ", x2 - x1 + 1))
  end
end

local function label(out, x, y, s, fg, bg, maxW)
  local w, h = out.getSize()
  if y < 1 or y > h or x > w then return end
  s = tostring(s or "")
  if x < 1 then
    s = s:sub(2 - x)
    x = 1
  end
  local room = math.min(w - x + 1, maxW or w)
  if room < 1 then return end
  out.setBackgroundColor(bg or colors.black)
  out.setTextColor(fg or colors.white)
  out.setCursorPos(x, y)
  out.write(s:sub(1, room))
end

local function centered(out, x, y, width, s, fg, bg)
  s = tostring(s or "")
  if #s > width then s = s:sub(1, width) end
  label(out, x + math.floor((width - #s) / 2), y, s, fg, bg, width)
end

local function meter(out, x, y, width, fraction, goodColor, background)
  width = math.max(1, width)
  fraction = clamp(tonumber(fraction) or 0, 0, 1)
  local count = math.floor(fraction * width + 0.5)
  rect(out, x, y, width, 1, background or colors.gray)
  if count > 0 then rect(out, x, y, count, 1, goodColor or colors.lime) end
end

local function pct(n)
  return string.format("%.1f%%", (tonumber(n) or 0) * 100)
end

local function value(n, fmt)
  if type(n) ~= "number" then return "--" end
  return string.format(fmt, n)
end

local function snapshot()
  if not last or not lastAt or (os.clock() - lastAt) > TIMEOUT then
    return nil, "SEM SINAL", colors.orange
  end
  if last.reason then return last.data, "BLOQUEADO", colors.red end
  if not last.data then return nil, "SEM LEITURA", colors.orange end
  if last.data.active then return last.data, "REATOR ATIVO", colors.lime end
  return last.data, "REATOR DESLIGADO", colors.lightGray
end

local function sectionTitle(out, x, y, title, maxW)
  label(out, x, y, title, colors.cyan, colors.black, maxW)
end

local function gaugeRow(out, x, y, width, title, fraction, fillColor)
  sectionTitle(out, x, y, title, width)
  local number = pct(fraction)
  label(out, x + width - #number, y, number, colors.white, colors.black)
  meter(out, x, y + 1, width, fraction, fillColor, colors.gray)
end

local function drawLarge(out, w, h, d, state, statusColor)
  local cw = math.min(w - 2, 94)
  local ch = math.min(h - 2, 31)
  local sx = math.floor((w - cw) / 2) + 1
  local sy = math.floor((h - ch) / 2) + 1
  rect(out, sx, sy, cw, ch, colors.gray)

  rect(out, sx, sy, cw, 3, colors.blue)
  centered(out, sx, sy + 1, cw, "CENTRAL DE ENERGIA  |  REATOR DE FISSAO", colors.white, colors.blue)

  rect(out, sx + 1, sy + 4, cw - 2, 2, colors.black)
  centered(out, sx + 1, sy + 4, cw - 2, state, statusColor, colors.black)

  local leftW = math.floor((cw - 4) / 2)
  local rightW = cw - leftW - 4
  local lx = sx + 1
  local rx = lx + leftW + 2
  local iy = sy + 7
  rect(out, lx, iy, leftW, 8, colors.black)
  rect(out, lx, iy + 9, leftW, 9, colors.black)
  rect(out, rx, iy, rightW, 18, colors.black)

  -- Bloco principal: producao
  sectionTitle(out, lx + 2, iy + 1, "PRODUCAO", leftW - 4)
  centered(out, lx, iy + 3, leftW, d and (value(d.burn, "%.2f") .. " mB/t") or "-- mB/t", colors.yellow, colors.black)
  centered(out, lx, iy + 5, leftW, "TAXA DE QUEIMA", colors.lightGray, colors.black)
  centered(out, lx, iy + 6, leftW, "Aquecimento: " .. (d and value(d.heating, "%.0f") or "--") .. " mB/t", colors.white, colors.black)

  -- Temperatura e dano
  sectionTitle(out, lx + 2, iy + 10, "TEMPERATURA", leftW - 4)
  centered(out, lx, iy + 12, leftW, (d and value(d.tempC, "%.2f") or "--") .. " C", colors.white, colors.black)
  meter(out, lx + 2, iy + 14, leftW - 4, d and d.tempC / 450 or 0, d and d.tempC >= 400 and colors.red or colors.lime, colors.gray)
  centered(out, lx, iy + 15, leftW, "Limite do controlador: 450 C", colors.lightGray, colors.black)
  centered(out, lx, iy + 16, leftW, "Dano: " .. (d and value(d.damage, "%.2f") or "--") .. "%", d and d.damage > 0 and colors.red or colors.white, colors.black)

  -- Fluidos
  sectionTitle(out, rx + 2, iy + 1, "REFRIGERACAO E RESIDUOS", rightW - 4)
  local bw = rightW - 4
  gaugeRow(out, rx + 2, iy + 4, bw, "SODIO", d and d.coolant or 0, d and d.coolant < 0.1 and colors.red or colors.cyan)
  gaugeRow(out, rx + 2, iy + 8, bw, "SODIO QUENTE", d and d.heated or 0, d and d.heated >= 0.9 and colors.red or colors.orange)
  gaugeRow(out, rx + 2, iy + 12, bw, "RESIDUO NUCLEAR", d and d.waste or 0, d and d.waste >= 0.85 and colors.red or colors.purple)
  label(out, rx + 2, iy + 16, "Protecoes independentes recomendadas", colors.lightGray, colors.black, rightW - 4)

  local warning = last and last.reason
  if warning then
    rect(out, sx + 1, sy + 26, cw - 2, 1, colors.red)
    centered(out, sx + 1, sy + 26, cw - 2, "ALARME: " .. tostring(warning), colors.white, colors.red)
  elseif not d then
    rect(out, sx + 1, sy + 26, cw - 2, 1, colors.orange)
    centered(out, sx + 1, sy + 26, cw - 2, "Sem telemetria recente do computador do reator", colors.black, colors.orange)
  else
    centered(out, sx + 1, sy + 26, cw - 2, "SEGURANCA LOCAL ATIVA - PAINEL SOMENTE LEITURA", colors.white, colors.gray)
  end

  local age = lastAt and (os.clock() - lastAt) or 0
  centered(out, sx, sy + ch - 1, cw, string.format("CANAL 42    |    ULTIMA LEITURA: %.1fs    |    v2.0", age), colors.lightGray, colors.gray)
end

local function drawCompact(out, w, h, d, state, statusColor)
  local bw = math.max(10, math.min(w - 4, 38))
  local cx = math.floor((w - bw) / 2) + 1
  rect(out, 1, 1, w, 2, colors.blue)
  centered(out, 1, 1, w, "PAINEL DO REATOR", colors.white, colors.blue)
  centered(out, 1, 3, w, state, statusColor, colors.black)

  local rows = {
    {"QUEIMA", d and (value(d.burn, "%.2f") .. " mB/t") or "--"},
    {"TEMPERATURA", d and (value(d.tempC, "%.2f") .. " C") or "--"},
    {"SODIO", d and pct(d.coolant) or "--"},
    {"SODIO QUENTE", d and pct(d.heated) or "--"},
    {"RESIDUO", d and pct(d.waste) or "--"},
    {"DANO", d and (value(d.damage, "%.2f") .. "%") or "--"},
    {"AQUECIMENTO", d and (value(d.heating, "%.0f") .. " mB/t") or "--"}
  }
  local startY = 5
  for i, row in ipairs(rows) do
    local y = startY + (i - 1) * (h >= 21 and 2 or 1)
    if y > h - 2 then break end
    local text = row[1] .. ": " .. row[2]
    centered(out, cx, y, bw, text, colors.white, colors.black)
  end
  if h >= 19 and d then
    meter(out, cx, h - 3, bw, d.coolant, colors.cyan, colors.gray)
  end
  if last and last.reason then
    centered(out, 1, h - 1, w, "ALARME: " .. tostring(last.reason), colors.red, colors.black)
  else
    centered(out, 1, h - 1, w, "Canal 42 | Somente leitura | v2.0", colors.lightGray, colors.black)
  end
end

local function draw(out)
  local w, h = out.getSize()
  local d, state, statusColor = snapshot()
  out.setBackgroundColor(colors.black)
  out.clear()
  if w >= 58 and h >= 30 then
    drawLarge(out, w, h, d, state, statusColor)
  else
    drawCompact(out, w, h, d, state, statusColor)
  end
end

local function redraw()
  draw(term)
  if screen then draw(screen) end
end

redraw()
local timer = os.startTimer(0.5)
while true do
  local ev, a, b, c, d = os.pullEvent()
  if ev == "modem_message" then
    local channel, msg = b, d
    if channel == CHANNEL and type(msg) == "table"
       and msg.kind == "mek_fission_telemetry_v1" then
      last, lastAt = msg, os.clock()
    end
  elseif ev == "timer" and a == timer then
    redraw()
    timer = os.startTimer(0.5)
  elseif ev == "monitor_resize" or ev == "term_resize" then
    redraw()
  end
end
