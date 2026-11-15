-- Passive diagnostics: run on the OUTSIDE display computer, never replaces control.
-- relatorio_reator [controller ID] [seconds]; defaults: configured ID/all, 60 s.
local idArg, secondsArg = ...
local source = tonumber(idArg) or settings.get("reator.source")
local seconds = tonumber(secondsArg) or 60
assert(seconds >= 5 and seconds <= 600 and seconds == math.floor(seconds), "Duracao: 5 a 600 segundos")
local CHANNEL, PATH = 42, "/relatorio_reator.txt"
local started, wall = os.clock(), os.epoch("utc")
local records, sources, last = {}, {}, {}
local counts = {received=0, selected=0, malformed=0, otherSource=0, omitted=0}
local notes, modems = {}, {}
local function finite(x) return type(x)=="number" and x==x and math.abs(x)<math.huge end
local function text(v) return type(v)=="string" and v:sub(1,500) or nil end
local function clean(t, numeric, textual, boolean)
  if type(t)~="table" then return nil end
  local out={}
  for _, k in ipairs(numeric or {}) do
    if finite(t[k]) then out[k]=t[k]
    elseif t[k]~=nil then out[k]="INVALIDO ("..type(t[k])..")" end
  end
  for _, k in ipairs(textual or {}) do out[k]=text(t[k]) end
  for _, k in ipairs(boolean or {}) do
    if type(t[k])=="boolean" then out[k]=t[k]
    elseif t[k]~=nil then out[k]="INVALIDO ("..type(t[k])..")" end
  end
  return out
end
for _, name in ipairs(peripheral.getNames()) do
  local p=peripheral.wrap(name)
  if p and type(p.open)=="function" and type(p.transmit)=="function" then
    local ok,err=pcall(p.open,CHANNEL)
    if ok then modems[#modems+1]=name else notes[#notes+1]="Modem: "..tostring(err) end
  end
end
local function receive(p, side, distance)
  counts.received=counts.received+1
  if type(p)~="table" or (p.kind~="mek_fission_telemetry_v1" and p.kind~="mek_fission_telemetry_v2") or
    not finite(p.source) then counts.malformed=counts.malformed+1 return end
  sources[tostring(p.source)]=true
  if source~=nil and p.source~=source then counts.otherSource=counts.otherSource+1 return end
  counts.selected=counts.selected+1
  local previous=last[p.source]
  local now=os.clock()
  local state=text(p.state) or "SEM ESTADO"
  local reason=text(p.reason) or ""
  local phase=type(p.trial)=="table" and text(p.trial.phase) or ""
  local burn=type(p.data)=="table" and finite(p.data.burn) and p.data.burn or nil
  local changed=not previous or previous.state~=state or previous.reason~=reason or
    previous.phase~=phase or previous.burn~=burn or previous.diskError~=text(p.diskError)
  if previous and not changed and now-previous.at<1 then return end
  if #records>=720 then counts.omitted=counts.omitted+1 return end
  local entry=clean(p,{"sequence","utc","readSeconds","duration","stabilize","sampleCount"},
    {"kind","edition","mode","state","reason","warning","diskError","uiError","reactor","session"},
    {"scramConfirmed"})
  entry.source,entry.receivedUTC,entry.elapsed=p.source,os.epoch("utc"),now-started
  entry.side,entry.distance=text(side),finite(distance) and distance or nil
  if finite(p.utc) then entry.ageMs=entry.receivedUTC-p.utc end
  entry.data=clean(p.data,{"tempC","coolant","heated","waste","fuel","damage","burn","actual","heating","maxBurn","readSeconds"},{},{"active"})
  entry.trial=clean(p.trial,{"target","elapsed","settle","duration","started","finished","maxTemp","minTemp","minCoolant","maxHeated","maxWaste","minFuel","sampleCount"},{"phase","reason","policy","supply"})
  entry.trend=clean(p.trend,{"temp","sodium","heated","waste","fuel"})
  entry.eta=clean(p.eta,{"tempC","coolant","heated","waste","fuel"})
  records[#records+1]=entry
  last[p.source]={at=now,state=state,reason=reason,phase=phase,burn=burn,diskError=text(p.diskError)}
end
print("RELATORIO PASSIVO: "..seconds.." segundos, canal "..CHANNEL)
print(source and ("Controlador escolhido: "..tostring(source)) or "Coletando IDs de todos os controladores compativeis")
print("Nao altera queima, nao liga e nao desliga o reator.")
if #modems==0 then notes[#notes+1]="NENHUM MODEM DISPONIVEL NO COMPUTADOR COLETOR"
else
  local timer=os.startTimer(seconds)
  while true do
    local event,a,b,c,message,distance=os.pullEventRaw()
    if event=="timer" and a==timer then break
    elseif event=="terminate" then notes[#notes+1]="COLETA ENCERRADA MANUALMENTE" break
    elseif event=="modem_message" and b==CHANNEL then receive(message,a,distance) end
  end
end
if counts.selected==0 then notes[#notes+1]="SEM TELEMETRIA DO CONTROLADOR SELECIONADO; NAO E EVIDENCIA DE REATOR DESLIGADO" end
local ids={} for id in pairs(sources) do ids[#ids+1]=id end table.sort(ids)
local lines={
  "RELATORIO DE DIAGNOSTICO DO REATOR / COLETOR 1.0",
  "Coleta passiva no computador externo; sensores reproduzidos da telemetria, sem verificacao independente.",
  "Computador coletor: "..os.getComputerID(), "Ambiente do coletor: "..tostring(_HOST or "desconhecido"),
  "Inicio UTC (ms): "..wall, "Fim UTC (ms): "..os.epoch("utc"),
  "Duracao observada (s): "..(os.clock()-started), "Canal: "..CHANNEL,
  "Filtro: "..tostring(source or "todos"), "Modems: "..table.concat(modems,", "),
  "IDs observados: "..table.concat(ids,", "),
  "Contagem: "..textutils.serializeJSON(counts),
  "Unidades: tempC=Celsius; tanques=fracao 0..1; burn/actual=mB/t.",
  "Tendencia V1: variacao em 30s. Tendencia V2: C/min e pontos percentuais/min.",
  "Este arquivo nao contem senhas, tokens, codigo dos programas ou arquivos pessoais.",
}
for _,note in ipairs(notes) do lines[#lines+1]="NOTA: "..note end
lines[#lines+1]="AMOSTRAS JSON (uma por linha; inclui mudancas de estado):"
for _,record in ipairs(records) do lines[#lines+1]=textutils.serializeJSON(record) end
-- Save a new complete report before replacing the previous one.
local f=assert(fs.open(PATH..".novo","w"),"Nao conseguiu criar o relatorio")
f.write(table.concat(lines,"\n").."\n") f.close()
if fs.exists(PATH) then
  if fs.exists(PATH..".anterior") then fs.delete(PATH..".anterior") end
  fs.move(PATH,PATH..".anterior")
end
fs.move(PATH..".novo",PATH)
print("Salvo: "..PATH.." | Amostras: "..#records)
print("Para publicar no Pastebin e obter um link:")
print("pastebin put "..PATH)
print("Depois reinicie seu painel: painel_auto <ID do controlador>")
