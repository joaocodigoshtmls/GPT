-- Read-only display. Pin the controller: settings set reator.source <computer ID>
local CHANNEL, SCALE = 42, 0.5
local expected = tonumber((...)) or settings.get("reator.source")
local latest, received, modem, monitor, page = nil, nil, nil, nil, 1
local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function accepts(p)
  if not finite(expected) or type(p) ~= "table" or p.kind ~= "mek_fission_telemetry_v2" or
    p.source ~= expected or p.mode ~= "auto" or type(p.session) ~= "string" or
    not finite(p.sequence) or p.sequence < 1 or p.sequence % 1 ~= 0 or
    not finite(p.utc) or math.abs(os.epoch("utc")-p.utc) > 5000 or
    type(p.state) ~= "string" or not finite(p.duration) or p.duration <= 0 or
    not finite(p.stabilize) or p.stabilize <= 0 then return false end
  for _, k in ipairs({"reactor", "reason", "diskError", "uiError", "warning"}) do
    if p[k] ~= nil and type(p[k]) ~= "string" then return false end
  end
  if p.scramConfirmed ~= nil and type(p.scramConfirmed) ~= "boolean" then return false end
  for _, k in ipairs({"data", "trial", "trend", "eta"}) do
    if p[k] ~= nil and type(p[k]) ~= "table" then return false end
  end
  if p.data then
    if type(p.data.active) ~= "boolean" then return false end
    for _, k in ipairs({"tempC", "coolant", "heated", "waste", "fuel", "damage", "burn", "actual", "heating"}) do
      if not finite(p.data[k]) then return false end
    end
    for _, k in ipairs({"coolant", "heated", "waste", "fuel"}) do
      if p.data[k] < 0 or p.data[k] > 1 then return false end
    end
  end
  if p.trial then
    for _, k in ipairs({"elapsed", "settle", "target", "maxTemp", "minCoolant", "maxHeated", "maxWaste", "minFuel"}) do
      if p.trial[k] ~= nil and not finite(p.trial[k]) then return false end
    end
    if p.trial.phase ~= nil and type(p.trial.phase) ~= "string" then return false end
    if p.trial.reason ~= nil and type(p.trial.reason) ~= "string" then return false end
  end
  for _, container in ipairs({p.trend or {}, p.eta or {}}) do
    for _, value in pairs(container) do if not finite(value) then return false end end
  end
  if latest then
    if p.utc < latest.utc then return false end
    if p.session == latest.session and p.sequence <= latest.sequence then return false end
  end
  return true
end
local function fmt(v, pattern, factor)
  return finite(v) and string.format(pattern, v*(factor or 1)) or "--"
end
local function clock(v)
  if not finite(v) then return "--" end
  v = math.max(0, math.ceil(v))
  if v > 86400 then return ">24h" end
  return string.format("%02d:%02d", math.floor(v/60), v%60)
end
local function groups(p)
  local d, t, tr, eta = p.data or {}, p.trial or {}, p.trend or {}, p.eta or {}
  local function pct(v) return fmt(v, "%.3f%%", 100) end
  return {
    {"OPERACAO", {
      "Alvo: " .. fmt(d.burn, "%.6g mB/t"), "Real: " .. fmt(d.actual, "%.6g mB/t"),
      "Temperatura: " .. fmt(d.tempC, "%.2f C"), "Dano: " .. fmt(d.damage, "%.2f%%"),
      "Leitura: " .. fmt(p.readSeconds, "%.3f s")}},
    {"RESERVAS", {
      "Refrigerante frio: " .. pct(d.coolant), "Quente: " .. pct(d.heated),
      "Residuo: " .. pct(d.waste), "Combustivel: " .. pct(d.fuel)}},
    {"TENDENCIAS (ULTIMOS 60 S)", {
      "Temperatura: " .. fmt(tr.temp, "%+.3f C/min"), "Frio: " .. fmt(tr.sodium, "%+.4f pp/min"),
      "Quente: " .. fmt(tr.heated, "%+.4f pp/min"), "Residuo: " .. fmt(tr.waste, "%+.4f pp/min"),
      "Combustivel: " .. fmt(tr.fuel, "%+.4f pp/min")}},
    {"AVALIACAO AUTOMATICA", {
      "Estado: " .. p.state, "Alvo: " .. fmt(t.target, "%.6g mB/t"),
      "Estabilidade: " .. clock(t.settle or 0) .. "/" .. clock(p.stabilize),
      "Medicao: " .. clock(t.elapsed or 0) .. "/" .. clock(p.duration),
      "Temp maxima: " .. fmt(t.maxTemp, "%.2f C"), t.reason or "Aguardando condicoes estaveis"}},
    {"TEMPO ESTIMADO ATE LIMITES", {
      "Temperatura: " .. clock(eta.tempC), "Frio: " .. clock(eta.coolant),
      "Quente: " .. clock(eta.heated), "Residuo: " .. clock(eta.waste), "Combustivel: " .. clock(eta.fuel),
      "Estimativas; -- = sem tendencia adversa"}},
  }
end
local function write(out, x, y, s, color, width)
  local w, h = out.getSize()
  if y < 1 or y > h or x > w then return end
  out.setCursorPos(x, y)
  out.setTextColor(color or colors.white)
  out.write(tostring(s):sub(1, math.max(0, math.min(width or w, w-x+1))))
end
local function draw(out)
  local w, h = out.getSize()
  out.setBackgroundColor(colors.black)
  out.clear()
  write(out, 1, 1, "BASTIAO DE ACO | PAINEL AUTO V2", colors.cyan)
  if not finite(expected) then
    write(out, 1, 3, "Configure o ID do computador controlador:", colors.orange)
    write(out, 1, 4, "settings set reator.source <ID>")
    write(out, 1, 5, "Depois reinicie painel_reator.")
    return
  end
  if not latest or os.clock()-received >= 3 or os.epoch("utc")-latest.utc >= 5000 then
    write(out, 1, 3, "SEM TELEMETRIA ATUAL - ESTADO DESCONHECIDO", colors.red)
    write(out, 1, 4, "Controlador esperado: " .. expected)
    return
  end
  local p = latest
  local status = p.reason and (p.scramConfirmed and "SCRAM CONFIRMADO" or "SCRAM NAO CONFIRMADO") or
    (p.data and (p.data.active and "LIGADO" or "DESLIGADO") or "SEM LEITURA")
  write(out, 1, 2, p.state .. " | " .. status, p.reason and colors.red or colors.lime)
  write(out, 1, 3, p.reason or p.diskError or p.uiError or "APROVACAO TEMPORARIA; SUPERVISAO CONTINUA", colors.yellow)
  local sections = groups(p)
  if w >= 64 and h >= 28 then
    local half = math.floor(w/2)
    for i, group in ipairs(sections) do
      local x, y = ((i-1)%2)*half+1, 5+math.floor((i-1)/2)*7
      write(out, x, y, group[1], colors.cyan, half-1)
      for j, line in ipairs(group[2]) do write(out, x, y+j, line, colors.white, half-1) end
    end
  else
    local lines = {}
    for _, group in ipairs(sections) do
      lines[#lines+1] = {group[1], colors.cyan}
      for _, line in ipairs(group[2]) do lines[#lines+1] = {line, colors.white} end
    end
    local capacity = math.max(1, h-5)
    local pages = math.ceil(#lines/capacity)
    local current = (page-1)%pages+1
    for i = 1, capacity do
      local line = lines[(current-1)*capacity+i]
      if line then write(out, 1, 3+i, line[1], line[2]) end
    end
    write(out, 1, h, string.format("%d/%d | seta direita ou toque", current, pages), colors.lightGray)
  end
end
local function redraw()
  pcall(draw, term)
  if monitor then pcall(draw, monitor) end
end
local function discover()
  modem = peripheral.find("modem")
  if modem then pcall(modem.open, CHANNEL) end
  local found = peripheral.find("monitor")
  if found then pcall(found.setTextScale, SCALE) end
  monitor = found
end
pcall(discover)
redraw()
local timer = os.startTimer(0.5)
while true do
  local event, a, b, c, message = os.pullEvent()
  if event == "modem_message" and b == CHANNEL and accepts(message) then
    latest, received = message, os.clock()
  elseif (event == "key" and a == keys.right) or event == "monitor_touch" then
    page = page+1
    redraw()
  elseif event == "timer" and a == timer then
    redraw()
    timer = os.startTimer(0.5)
  elseif event == "monitor_resize" or event == "term_resize" then redraw()
  elseif event == "peripheral" or event == "peripheral_detach" then pcall(discover) end
end
