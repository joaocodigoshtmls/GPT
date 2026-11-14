-- Olho de Redstone | somente leitura | CC:Tweaked
local CHANNEL, SCALE = 42, 0.5
local modem = peripheral.find("modem")
if not modem then error("Modem nao encontrado neste computador.", 0) end
modem.open(CHANNEL)
local monitor = peripheral.find("monitor")
if monitor then monitor.setTextScale(SCALE) end

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
  fraction = math.max(0, math.min(1, fraction))
  rect(out, x, y, width, 1, colors.gray)
  local filled = math.floor(width * fraction + 0.5)
  if filled > 0 then rect(out, x, y, filled, 1, fg) end
end

local latest, received, page = nil, nil, 1
local function fmt(value, pattern, scale)
  if type(value) ~= "number" then return "--" end
  return string.format(pattern, value * (scale or 1))
end
local function pct(v) return fmt(v, "%.1f%%", 100) end

local function details(p)
  local d, t, tr = p.data or {}, p.trial or {}, p.trend or {}
  local left = math.max(0, math.ceil(300 - (t.elapsed or 0)))
  local clock = string.format("%02d:%02d", math.floor(left/60), left%60)
  local sections = {
    {"OPERACAO", {
      {"Queima real", fmt(d.actual, "%.2f mB/t")},
      {"Configurada", fmt(d.burn, "%.2f mB/t")},
      {"Temperatura", fmt(d.tempC, "%.2f C")},
      {"Aquecimento", fmt(d.heating, "%.0f mB/t")},
      {"Dano", fmt(d.damage, "%.2f%%")}}},
    {"TANQUES DO REATOR", {
      {"Sodio frio", pct(d.coolant), d.coolant, colors.cyan},
      {"Sodio quente", pct(d.heated), d.heated, colors.orange},
      {"Residuos", pct(d.waste), d.waste, colors.purple},
      {"Combustivel", pct(d.fuel), d.fuel, colors.lime}}},
    {"TENDENCIA EM 30 S", {
      {"Temperatura", fmt(tr.temp, "%+.2f C")},
      {"Sodio frio", fmt(tr.sodium, "%+.2f pp")}}}
  }
  if p.mode == "teste" then
    sections[#sections+1] = {"TESTE  |  " .. clock, {
      {"Estado", t.phase}, {"Alvo", fmt(t.target, "%.2f mB/t")},
      {"Reposicao", t.supply}, {"Temp. maxima", fmt(t.maxTemp, "%.2f C")},
      {"Sodio minimo", pct(t.minCoolant)}, {"Quente max.", pct(t.maxHeated)},
      {"Residuo max.", pct(t.maxWaste)}}}
  else
    local ref = p.reference or {}
    sections[#sections+1] = {"REFERENCIA DO TESTE", {
      {"Taxa aprovada", fmt(ref.target, "%.2f mB/t")}, {"Reposicao", ref.supply}}}
  end
  if p.reason then
    local trip = (p.trip and p.trip.data) or {}
    table.insert(sections, 1, {"DISPARO DO SCRAM", {
      {"Sodio no disparo", pct(trip.coolant)}, {"Sodio agora", pct(d.coolant)},
      {"Temp. no disparo", fmt(trip.tempC, "%.2f C")}, {"Queima real", fmt(trip.actual, "%.2f mB/t")},
      {"Apos SCRAM", p.cooling or "SEM DADOS"}}})
  end
  return sections
end

local function draw(out)
  local w, h = out.getSize()
  out.setBackgroundColor(colors.black)
  out.clear()
  rect(out, 1, 1, w, 1, colors.red)
  middle(out, 1, 1, w, "OLHO DE REDSTONE", colors.white, colors.red)
  if not latest or os.clock() - received >= 5 then
    middle(out, 1, math.max(2, math.ceil(h/2)), w, "SEM SINAL", colors.orange)
    return
  end
  local p = latest
  local status = p.reason and (p.scramConfirmed and "SCRAM CONFIRMADO" or "SCRAM NAO CONFIRMADO")
    or (p.data and (p.data.active and "LIGADO" or "DESLIGADO") or "SEM LEITURA")
  local stateColor = p.reason and colors.red or colors.cyan
  middle(out, 1, 2, w, (p.mode or "legado"):upper() .. "  |  " .. status, stateColor)
  local notice = p.reason or p.diskError or p.warning or (p.trial and p.trial.reason)
    or (p.edition ~= "bastiao" and "ATUALIZE O CONTROLADOR") or "Monitoramento ativo"
  middle(out, 1, 3, w, notice, colors.yellow)
  local groups = details(p)

  -- Telas grandes distribuem as secoes pela altura e largura disponiveis.
  if w >= 58 and h >= 5 + 8 * math.ceil(#groups / 2) then
    local rows = math.ceil(#groups / 2)
    for i, group in ipairs(groups) do
      local row, col = math.floor((i-1)/2), (i-1)%2
      local x = 1 + math.floor(col*w/2)
      local width = math.floor((col+1)*w/2) - x
      local y = 5 + math.floor(row*(h-5)/rows)
      local bottom = 4 + math.floor((row+1)*(h-5)/rows)
      rect(out, x, y, width, bottom-y+1, colors.gray)
      middle(out, x, y, width, group[1], colors.cyan, colors.gray)
      for j, item in ipairs(group[2]) do
        local line = y + 1 + math.floor((j-1)*(bottom-y)/#group[2])
        local value = item[2] or "--"
        write(out, x+1, line, item[1], colors.white, colors.gray, width-#value-3)
        write(out, x+width-#value-1, line, value, colors.white, colors.gray)
        if item[3] and (bottom-y)/#group[2] >= 2 then
          bar(out, x+1, line+1, width-2, item[3], item[4])
        end
      end
    end
  else
    local lines = {}
    for _, group in ipairs(groups) do
      lines[#lines+1] = {group[1], colors.cyan}
      for _, item in ipairs(group[2]) do
        lines[#lines+1] = {item[1] .. ": " .. (item[2] or "--"), colors.white}
      end
    end
    local perPage = math.max(1, h-4)
    local pages = math.ceil(#lines/perPage)
    local current = (page-1)%pages+1
    for i=1, perPage do
      local line = lines[(current-1)*perPage+i]
      if line then middle(out, 1, i+3, w, line[1], line[2]) end
    end
    middle(out, 1, h, w, string.format("%d/%d  > ou toque", current, pages), colors.lightGray)
  end
end

local function redraw()
  draw(term)
  if monitor then draw(monitor) end
end
local function accepts(p)
  if type(p) ~= "table" or p.kind ~= "mek_fission_telemetry_v1" then return false end
  for _, field in ipairs({"data","trip","trend","trial","reference"}) do
    if p[field] ~= nil and type(p[field]) ~= "table" then return false end
  end
  return not p.mode or p.mode == "teste" or p.mode == "normal"
end

local timer = os.startTimer(0.5)
redraw()
while true do
  local event, a, b, c, message = os.pullEvent()
  if event == "modem_message" and b == CHANNEL and accepts(message) then
    latest, received = message, os.clock()
  elseif event == "key" and a == keys.right or event == "monitor_touch" then
    page = page + 1
    redraw()
  elseif event == "timer" and a == timer then
    redraw()
    timer = os.startTimer(0.5)
  elseif event == "monitor_resize" or event == "term_resize" then
    redraw()
  end
end
