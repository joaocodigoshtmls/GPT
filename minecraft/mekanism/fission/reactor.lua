-- Adapted from MohammedMMC/FissionReactor-CC (GPL-3.0).
-- Original four resource bars and right-hand controls; bridge owns protection.
local function loadConfig()
  if fs and shell and shell.getRunningProgram then
    return dofile(fs.combine(fs.getDir(shell.getRunningProgram()),'config.lua'))
  end
  return require('config')
end
local ok, config = pcall(loadConfig)
if not ok or type(config) ~= 'table' then config = {} end
local expected = tonumber((...)) or tonumber(config.CONTROLLER_ID)
local CHANNEL = tonumber(config.MODEM_CHANNEL) or 43
local STEP = tonumber(config.BURN_STEP) or 0.5
local REFRESH = tonumber(config.UI_REFRESH) or 0.5
local STALE = tonumber(config.TELEMETRY_STALE_SECONDS) or 5
local SENSOR_STALE = math.min(STALE,tonumber(config.MAX_SAMPLE_GAP) or STALE)
local MAX_AGE = tonumber(config.PACKET_MAX_AGE_SECONDS) or 8
local COMMAND_TIMEOUT = tonumber(config.COMMAND_TIMEOUT_SECONDS) or 8
local C = colors or colours
local ownID = os.getComputerID()
local latest, received, pending, notice
local commandID = math.floor(os.epoch('utc')) * 1000
local modems, outputs, buttons = {}, {}, {}
local running = true
local testNames = {IDLE='NAO TESTADO', WAITING='AGUARDANDO', WARMUP='AQUECENDO',
  STABILIZING='ESTABILIZANDO', MEASURING='MEDINDO', PASSED='APROVADO',
  FAILED='INTERROMPIDO', ABORTED='CANCELADO', CANCELLED='CANCELADO'}
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function integer(v) return finite(v) and v>=0 and v%1==0 and v<9007199254740992 end
local function short(s) return type(s)=='string' and s:sub(1,500) or nil end
local function fmt(v, digits)
  if not finite(v) then return '--' end
  return string.format('%.' .. (digits or 2) .. 'f', v)
end
local function clock(v)
  if not finite(v) then return '--:--' end
  v=math.max(0,math.floor(v))
  return string.format('%02d:%02d',math.floor(v/60),v%60)
end
local function freshPacket()
  return latest and received and os.clock()-received < STALE and
    os.epoch('utc')-latest.utc < MAX_AGE*1000 and os.epoch('utc')>=latest.utc-1000
end
local function freshData()
  return freshPacket() and latest.data and
    latest.safety.ageSeconds+math.max(0,os.clock()-received) < SENSOR_STALE
end
local function validData(d)
  if type(d)~='table' or type(d.active)~='boolean' then return false end
  for _,k in ipairs({'dmg','temp','heatRate','br','actual','brMax','brPct',
      'fuelPct','wastePct','coolPct','hotPct'}) do
    if not finite(d[k]) then return false end
  end
  for _,k in ipairs({'brPct','fuelPct','wastePct','coolPct','hotPct'}) do
    if d[k]<0 or d[k]>100 then return false end
  end
  return d.temp>=0 and d.dmg>=0 and d.dmg<=100 and d.heatRate>=0 and
    d.brMax>0 and d.br>=0 and d.actual>=0 and d.br<=d.brMax+1e-6 and d.actual<=d.brMax+1e-6
end
local function validTelemetry(p)
  if not integer(expected) or type(p)~='table' or p.type~='fission_data_v3' or
      p.protocol~=3 or p.source~=expected or type(p.session)~='string' or
      #p.session==0 or #p.session>100 or not integer(p.sequence) or p.sequence<1 or
      not finite(p.utc) or os.epoch('utc')-p.utc>MAX_AGE*1000 or p.utc-os.epoch('utc')>1000 or
      type(p.safety)~='table' or type(p.safety.blocked)~='boolean' then return false end
  if p.safety.scramConfirmed~=nil and type(p.safety.scramConfirmed)~='boolean' then return false end
  for _,k in ipairs({'reason','lastError','storageError'}) do
    if p.safety[k]~=nil and type(p.safety[k])~='string' then return false end
  end
  for _,k in ipairs({'readSeconds','ageSeconds'}) do
    if p.safety[k]~=nil and (not finite(p.safety[k]) or p.safety[k]<0) then return false end
  end
  if p.data~=nil and (not validData(p.data) or not finite(p.safety.ageSeconds) or
      p.safety.ageSeconds<0) then return false end
  if p.data==nil and not p.safety.blocked then return false end
  if type(p.test)~='table' or not testNames[p.test.state] then return false end
  for _,k in ipairs({'target','settle','elapsed','duration','stableSeconds'}) do
    if p.test[k]~=nil and (not finite(p.test[k]) or p.test[k]<0) then return false end
  end
  if p.test.reason~=nil and type(p.test.reason)~='string' then return false end
  if p.test.slopes~=nil then
    if type(p.test.slopes)~='table' then return false end
    for _,k in ipairs({'tempC','coolant','fuel','heated','waste'}) do
      if p.test.slopes[k]~=nil and not finite(p.test.slopes[k]) then return false end
    end
  end
  if latest and (p.utc<latest.utc or
      (p.session==latest.session and p.sequence<=latest.sequence)) then return false end
  return true
end
local function transmit(packet)
  local sent=false
  for _,m in ipairs(modems) do
    local success=pcall(m.transmit,CHANNEL,CHANNEL,packet)
    if success then sent=true end
  end
  return sent
end
local function request(cmd,value)
  if not integer(expected) or not latest then notice='Configure o ID do reator'; return end
  if cmd~='scram' and not freshData() then notice='Sem leitura atual: comando bloqueado'; return end
  if pending and cmd~='scram' then notice='Aguardando confirmacao do comando'; return end
  if cmd=='setStatus' and value==true and latest.safety.blocked then
    notice='Libere o bloqueio com o reator desligado'; return
  end
  commandID=commandID+1
  local p={type='fission_command_v3',protocol=3,source=ownID,target=expected,
    session=latest.session,id=commandID,utc=os.epoch('utc'),cmd=cmd,value=value}
  if not transmit(p) then notice='Falha de modem: comando nao enviado'; return end
  pending={id=p.id,cmd=cmd,value=value,session=p.session,sent=os.clock(),
    sequence=latest.sequence,ack=false}
  notice='Enviado; aguardando confirmacao'
end
local function observed(p)
  if not pending or not pending.ack or p.session~=pending.session or
      p.sequence<=pending.sequence or not p.data then return false end
  if pending.cmd=='setBurnRate' then return math.abs(p.data.br-pending.value)<=1e-6 end
  if pending.cmd=='setStatus' then return p.data.active==pending.value end
  if pending.cmd=='clearFault' then return not p.safety.blocked and not p.data.active end
  if pending.cmd=='scram' or pending.cmd=='cancelTest' then
    return not p.data.active and p.safety.scramConfirmed==true
  end
  if pending.cmd=='startTest' then
    return p.test.state=='WAITING' or p.test.state=='WARMUP' or p.test.state=='STABILIZING' or
      p.test.state=='MEASURING' or p.test.state=='PASSED'
  end
  return false
end
local function receive(p)
  if validTelemetry(p) then
    if latest and p.session~=latest.session then
      pending=nil; notice='Controlador reiniciado; revise o estado'
    end
    latest,received=p,os.clock()
    if observed(p) then pending=nil; notice='Comando confirmado por leitura nova' end
  elseif type(p)=='table' and p.type=='fission_ack_v3' and p.protocol==3 and pending and
      p.source==expected and p.target==ownID and p.session==pending.session and
      p.id==pending.id and type(p.ok)=='boolean' and
      (p.reason==nil or type(p.reason)=='string') then
    if p.ok then
      pending.ack=true; notice='Aceito; aguardando leitura nova'
      if latest and observed(latest) then pending=nil; notice='Comando confirmado por leitura nova' end
    else
      pending=nil; notice='RECUSADO: '..(short(p.reason) or 'sem motivo informado')
    end
  end
end
local function discover()
  modems={peripheral.find('modem')}
  for _,m in ipairs(modems) do pcall(m.open,CHANNEL) end
  outputs={{name='terminal',out=term}}
  for _,name in ipairs(peripheral.getNames()) do
    local success,kind=pcall(peripheral.getType,name)
    if success and kind=='monitor' then
      local wrapped,out=pcall(peripheral.wrap,name)
      if wrapped and out then
        if out.setTextScale then pcall(out.setTextScale,0.5) end
        if out.setPaletteColor then pcall(out.setPaletteColor,C.pink,0xF2/255,0xD7/255,0xB6/255) end
        outputs[#outputs+1]={name=name,out=out}
      end
    end
  end
end
local function draw(output)
  local out,name=output.out,output.name
  local w,h=out.getSize()
  local function put(x,y,text,fg,bg,width)
    if y<1 or y>h or x>w then return end
    local length=math.max(0,math.min(width or w,w-x+1))
    if length==0 then return end
    out.setCursorPos(math.max(1,x),y)
    out.setBackgroundColor(bg or C.black); out.setTextColor(fg or C.white)
    out.write(tostring(text):sub(1,length))
  end
  local function rect(x,y,width,height,color)
    for row=0,height-1 do put(x,y+row,string.rep(' ',math.max(0,width)),C.white,color,width) end
  end
  local newButtons={}
  local function button(id,x,y,width,height,label,color,fn)
    if width<1 or height<1 then return end
    rect(x,y,width,height,color)
    put(x+math.max(0,math.floor((width-#label)/2)),y+math.floor((height-1)/2),label,C.white,color,width)
    newButtons[id]={x=x,y=y,w=width,h=height,fn=fn}
  end
  local data=freshData() and latest.data or nil
  local packet=freshPacket() and latest or nil
  local test=packet and packet.test or {state='IDLE'}
  local safety=packet and packet.safety or {}
  local rightW=math.max(15,math.floor(w*.23))
  if w-rightW<25 then rightW=math.max(12,w-25) end
  if w<30 then rightW=math.max(10,math.floor(w*.45)) end
  local leftW=math.max(1,w-rightW-1)
  rightW=w-leftW-1
  local rightX=leftW+2
  local boxH=math.max(1,math.floor(h/4))
  local slopes=test.slopes or {}
  local function resourceBox(order,title,pct,col,trend)
    local y=1+(order-1)*boxH
    local height=order==4 and h-(order-1)*boxH or boxH
    rect(1,y,leftW,height,C.black)
    local titleY=y+(height>=4 and 1 or 0)
    put(2,titleY,title,C.white,C.black,leftW-2)
    local text=finite(pct) and fmt(pct,3)..'%' or '--'
    put(math.max(2,leftW-#text),titleY,text,C.white,C.black,#text)
    if height>=6 then
      local change=finite(trend) and string.format('%+.4f pp/min',trend*6000) or '--'
      put(2,titleY+1,'Tendencia: '..change,C.lightGray,C.black,leftW-2)
    end
    local reserved=height>=4 and 3 or 1
    local areaH=math.max(0,height-reserved-(order==4 and height>=4 and 1 or 0))
    local fill=finite(pct) and math.floor(leftW*math.max(0,math.min(100,pct))/100+.5) or 0
    for row=0,areaH-1 do
      if fill>0 then put(1,y+reserved+row,string.rep(' ',fill),C.white,col,fill) end
    end
    if not finite(pct) and areaH>0 then put(2,y+reserved,'SEM LEITURA',C.orange,C.black,leftW-2) end
  end
  resourceBox(1,'Coolant',data and data.coolPct,C.lightBlue,slopes.coolant)
  resourceBox(2,'Fuel',data and data.fuelPct,C.gray,slopes.fuel)
  resourceBox(3,'Heated Coolant',data and data.hotPct,C.pink,slopes.heated)
  resourceBox(4,'Waste',data and data.wastePct,C.brown,slopes.waste)
  local topH=math.floor(h/2)
  local bottomY,bottomH=topH+1,h-topH
  rect(rightX,1,rightW,topH,C.gray)
  local btnH=math.max(2,math.floor(topH/2))
  local status=data and (data.active and 'ONLINE' or 'OFFLINE') or 'SEM DADOS'
  local statusColor=not data and C.gray or safety.blocked and C.magenta or data.active and C.lime or C.red
  button('onoff',rightX,1,rightW,btnH,status,statusColor,function()
    if not freshData() or latest.data.active or latest.safety.blocked then request('scram')
    else request('setStatus',true) end
  end)
  local reason=safety.lastError or safety.storageError or safety.reason or test.reason
  local testText=data and (testNames[test.state] or test.state) or 'DESCONHECIDO'
  local info={
    'Temp: '..(data and fmt(data.temp-273.15)..' C' or '--'),
    'Teste: '..testText,
    'Real: '..(data and fmt(data.actual)..' mB/t' or '--'),
    'Dano: '..(data and fmt(data.dmg)..'%' or '--'),
    'Estab: '..clock(test.settle)..'/'..clock(test.stableSeconds or config.STABLE_SECONDS or 120),
    'Medir: '..clock(test.elapsed)..'/'..clock(test.duration or config.MEASURE_SECONDS or 600),
    'Leitura: '..fmt(safety.readSeconds,3)..' s',
    'Heat: '..(data and fmt(data.heatRate)..' mB/t' or '--'),
    'Reator ID: '..tostring(expected or '?'),
    'Painel ID: '..ownID,
  }
  local controls=2
  local first=btnH+1
  local last=topH-controls
  local slots=math.max(0,last-first+1)
  local reasonLines=reason and math.min(2,math.max(1,math.floor(slots/3))) or 0
  local noticeLines=notice and slots>=6 and 1 or 0
  local limit=math.max(0,slots-reasonLines-noticeLines)
  for i=1,math.min(limit,#info) do put(rightX+1,first+i-1,info[i],C.white,C.gray,rightW-2) end
  local nextY=first+math.min(limit,#info)
  if reason then
    for i=1,reasonLines do
      put(rightX+1,nextY,reason:sub((i-1)*math.max(1,rightW-2)+1,i*math.max(1,rightW-2)),C.yellow,C.gray,rightW-2)
      nextY=nextY+1
    end
  end
  if noticeLines>0 then put(rightX+1,nextY,notice,C.yellow,C.gray,rightW-2) end
  local isTesting=test.state=='WAITING' or test.state=='WARMUP' or test.state=='STABILIZING' or test.state=='MEASURING'
  button('test',rightX+1,topH-1,rightW-2,1,isTesting and 'CANCELAR TESTE' or 'TESTAR TAXA',
    isTesting and C.orange or C.blue,function() request(isTesting and 'cancelTest' or 'startTest') end)
  button('release',rightX+1,topH,rightW-2,1,safety.blocked and 'LIBERAR BLOQUEIO' or 'PROTECAO ATIVA',
    safety.blocked and C.magenta or C.green,function()
      if freshData() and latest.safety.blocked and not latest.data.active then request('clearFault')
      else notice='Protecao permanece ativa' end
    end)
  rect(rightX,bottomY,rightW,bottomH,C.gray)
  local buttonH=bottomH>=8 and 3 or bottomH>=6 and 2 or 1
  local reserved=math.min(3,math.max(1,bottomH-buttonH-1))
  rect(rightX,bottomY,rightW,reserved,C.black)
  put(rightX+1,bottomY,'Burn Rate',C.white,C.black,rightW-2)
  put(rightX+1,bottomY+1,(data and fmt(data.br)..'/'..fmt(data.brMax,0) or '--/--')..' mB/t',C.white,C.black,rightW-2)
  if reserved>=3 then
    local text='Teste: '..clock(test.elapsed)..'/'..clock(test.duration or config.MEASURE_SECONDS or 600)
    put(rightX+1,bottomY+2,text,C.lightGray,C.black,rightW-2)
  end
  local barH=math.max(0,bottomH-reserved-buttonH)
  local fill=data and math.floor(barH*data.brPct/100+.5) or 0
  for i=0,barH-1 do rect(rightX,bottomY+reserved+i,rightW,1,i>=barH-fill and C.orange or C.black) end
  local function adjust(dir)
    if not freshData() then notice='Sem leitura atual'; return end
    if not finite(STEP) or STEP<=0 then notice='BURN_STEP invalido'; return end
    local value=math.max(0,math.min(latest.data.brMax,latest.data.br+STEP*dir))
    value=math.floor(value*1000000+.5)/1000000
    if math.abs(value-latest.data.br)>1e-6 then request('setBurnRate',value) end
  end
  local half=math.floor(rightW/2)
  local buttonY=h-buttonH+1
  button('dec',rightX,buttonY,half,buttonH,'-',C.red,function() adjust(-1) end)
  button('inc',rightX+half,buttonY,rightW-half,buttonH,'+',C.green,function() adjust(1) end)
  if not integer(expected) then
    put(2,1,'Execute reactor <ID do reator> | ID deste painel: '..ownID,C.yellow,C.black,leftW-2)
  elseif not packet then
    put(2,1,'SEM TELEMETRIA ATUAL | Reator '..expected,C.orange,C.black,leftW-2)
  elseif not data then
    put(2,1,'SEM LEITURA CONFIAVEL | '..(safety.reason or 'estado desconhecido'),C.orange,C.black,leftW-2)
  elseif safety.blocked then
    local text='BLOQUEADO | '..(safety.scramConfirmed and 'SCRAM CONFIRMADO' or 'SCRAM NAO CONFIRMADO')
    put(2,1,text..(notice and ' | '..notice or ''),C.yellow,C.black,leftW-2)
  elseif pending then
    put(2,1,'COMANDO PENDENTE: '..pending.cmd,C.yellow,C.black,leftW-2)
  elseif notice then put(2,1,notice,C.yellow,C.black,leftW-2)
  end
  buttons[name]=newButtons
end
local function redraw()
  if pending and os.clock()-pending.sent>=COMMAND_TIMEOUT then
    pending=nil; notice='SEM CONFIRMACAO: confira o controlador'
  end
  for _,out in ipairs(outputs) do pcall(draw,out) end
end
local function click(name,x,y)
  if not finite(x) or not finite(y) then return end
  for _,b in pairs(buttons[name] or {}) do
    if x>=b.x and x<b.x+b.w and y>=b.y and y<b.y+b.h then b.fn(); return end
  end
end
local function pause(seconds)
  local timer=os.startTimer(seconds)
  while running do
    local ev,id=os.pullEventRaw()
    if ev=='terminate' then running=false; return end
    if ev=='timer' and id==timer then return end
  end
end
local function networkLoop()
  while running do
    local ev,side,ch,reply,p=os.pullEventRaw()
    if ev=='terminate' then running=false; return end
    if ev=='modem_message' and ch==CHANNEL then receive(p)
    elseif ev=='peripheral' or ev=='peripheral_detach' then pcall(discover) end
  end
end
local function drawLoop()
  while running do redraw(); pause(REFRESH) end
end
local function inputLoop()
  while running do
    local ev,a,b,c=os.pullEventRaw()
    if ev=='terminate' then running=false; return end
    if ev=='monitor_touch' then click(a,b,c)
    elseif ev=='mouse_click' then click('terminal',b,c) end
  end
end
assert(parallel and parallel.waitForAny,'CC:Tweaked parallel API necessaria')
pcall(discover)
if #outputs==0 then outputs={{name='terminal',out=term}} end
parallel.waitForAny(networkLoop,drawLoop,inputLoop)
print('Painel encerrado. A protecao continua no computador do reator.')
