-- Reactor-side controller adapted from MohammedMMC/FissionReactor-CC (GPLv3).
-- Local protection owns all decisions; panel requests are manual commands only.
local DIR=fs.getDir(shell.getRunningProgram())
local LOCK,BINDING,RESULTS='/fission_lock_v3.json','/fission_binding_v3.json','/fission_results_v3.jsonl'
local ID=os.getComputerID()
local session=tostring(os.epoch('utc'))..':'..tostring(ID)
local args={...}
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function integer(v) return finite(v) and v>=0 and v%1==0 and v<9007199254740992 end
local function emergencyStop(name)
  local any,all=false,true
  local ok,names=pcall(peripheral.getNames)
  if not ok then return false end
  for _,n in ipairs(names) do
    if not name or name==n then
      local wrapped,p=pcall(peripheral.wrap,n)
      if wrapped and p and type(p.scram)=='function' and type(p.getStatus)=='function' and type(p.getBurnRate)=='function' then
        any=true
        local stopped=pcall(function()
          local active=p.getStatus()
          if active~=false then p.scram() end
          assert(p.getStatus()==false,'SCRAM nao confirmado')
        end)
        if not stopped then all=false end
      end
    end
  end
  return any and all
end
-- First action: shutdown request, even if a module/configuration is broken.
emergencyStop()
local config,adapter,engine,state,trip,publish
local function pause(seconds)
  local timer=os.startTimer(seconds)
  while true do local event,id=os.pullEventRaw() if event=='timer' and id==timer then return end end
end
local function readJSON(path)
  assert(fs.getSize(path)<=65536,'Arquivo grande demais: '..path)
  local f=assert(fs.open(path,'r'),'Nao abriu '..path)
  local raw=f.readAll() f.close()
  local value=textutils.unserializeJSON(raw)
  assert(type(value)=='table','Arquivo ilegivel: '..path)
  return value
end
local function atomicJSON(path,value)
  local f=assert(fs.open(path..'.tmp','w'),'Nao criou '..path)
  f.write(textutils.serializeJSON(value)) f.close()
  local marker=assert(fs.open(path..'.pending','w')) marker.write('pending') marker.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(path..'.tmp',path) fs.delete(path..'.pending')
end
local function transmit(packet)
  local ok,modems=pcall(function() return {peripheral.find('modem')} end)
  if not ok then return end
  for _,m in ipairs(modems) do pcall(m.transmit,config.MODEM_CHANNEL,config.MODEM_CHANNEL,packet) end
end
local function openModems()
  for _,m in ipairs({peripheral.find('modem')}) do pcall(m.open,config.MODEM_CHANNEL) end
end
local function startMargin(d)
  if not d or d.active then return 'Desligue o reator antes de liberar' end
  if d.damage>config.DAMAGE_MAX then return 'Dano no reator' end
  if d.tempC>config.TEMP_START_MAX_C then return 'Temperatura acima da margem de inicio' end
  if d.coolant<config.COOLANT_START_MIN then return 'Refrigerante abaixo da margem de inicio' end
  if d.fuel<config.FUEL_START_MIN then return 'Combustivel abaixo da margem de inicio' end
  if d.heated>config.HEATED_START_MAX then return 'Refrigerante quente acima da margem de inicio' end
  if d.waste>config.WASTE_START_MAX then return 'Residuo acima da margem de inicio' end
end
local function logResult(t)
  if not t or not t.resultUtc or t.resultUtc==state.loggedResult then return end
  if fs.exists(RESULTS) and fs.getSize(RESULTS)>512000 then
    if fs.exists(RESULTS..'.old') then fs.delete(RESULTS..'.old') end
    fs.move(RESULTS,RESULTS..'.old')
  end
  local f=assert(fs.open(RESULTS,'a'),'Nao abriu registro de testes')
  f.writeLine(textutils.serializeJSON({utc=os.epoch('utc'),controller=ID,reactor=adapter.name,test=t}))
  f.close() state.loggedResult=t.resultUtc
end
local function nowFresh()
  return state.data and state.freshAt and os.clock()-state.freshAt>=0 and
    os.clock()-state.freshAt<=config.MAX_SAMPLE_GAP and
    os.epoch('utc')>=state.freshUTC and os.epoch('utc')-state.freshUTC<=config.MAX_SAMPLE_GAP*1000
end
local function stopBound()
  local ok,stopped,err=pcall(function() return adapter:scram() end)
  state.confirmed=ok and stopped==true
  if not state.confirmed then state.stopError=tostring(ok and err or stopped) end
  if state.confirmed then state.stopError=nil end
end
trip=function(reason)
  local changed=not state.blocked or state.initial
  if changed then
    state.reason=tostring(reason) state.initial=false state.generation=state.generation+1
  end
  state.blocked=true
  state.lastError=tostring(reason)
  if engine and engine.fail then engine:fail(state.reason,os.epoch('utc')) end
  stopBound() -- Always BEFORE persistence, rendering and telemetry.
  if changed then state.lockDirty=true end
end
publish=function()
  state.sequence=state.sequence+1
  local d=nowFresh() and state.data or nil
  if d and state.blocked and state.confirmed and d.active then d=nil end
  local payload
  if d then
    payload={active=d.active,dmg=d.damage,temp=d.tempC+273.15,heatRate=d.heating,
      br=d.burn,actual=d.actual,brMax=d.maxBurn,brPct=d.burn/d.maxBurn*100,
      fuelPct=d.fuel*100,wastePct=d.waste*100,coolPct=d.coolant*100,hotPct=d.heated*100}
  end
  local t=engine:status()
  transmit({type='fission_data_v3',protocol=3,source=ID,session=session,sequence=state.sequence,
    utc=os.epoch('utc'),data=payload,test=t,
    safety={blocked=state.blocked,reason=state.reason,scramConfirmed=state.confirmed,
      readSeconds=state.lastRead,ageSeconds=state.freshAt and os.clock()-state.freshAt or nil,
      lastError=state.lastError,storageError=state.storageError}})
  pcall(function()
    term.setBackgroundColor(colors.black) term.setTextColor(colors.white) term.clear() term.setCursorPos(1,1)
    print('FISSION | CONTROLADOR LOCAL | CELSIUS')
    print('ID: '..ID..' | Painel autorizado: '..tostring(config.PANEL_ID))
    print('Adaptador: '..tostring(adapter.name))
    print(state.blocked and ('BLOQUEADO: '..tostring(state.reason)) or 'PROTECAO ATIVA')
    if d then
      print(string.format('%.2f C | Alvo %.2f / Real %.2f mB/t',d.tempC,d.burn,d.actual))
      print(string.format('Frio %.4f%% | Combustivel %.4f%%',d.coolant*100,d.fuel*100))
    else print('SEM LEITURA NOVA CONFIAVEL') end
    print('Teste: '..tostring(t.state)..' | '..tostring(t.reason or ''))
    if state.blocked then print(state.confirmed and 'SCRAM CONFIRMADO' or 'SCRAM NAO CONFIRMADO') end
    if state.lastRead then print(string.format('Leitura %.3fs | limite %.1fs',state.lastRead,config.MAX_SAMPLE_GAP)) end
    if state.storageError then print(state.storageError) end
    print('S: SCRAM | U: liberar desligado | T: armar teste')
  end)
end
local function persist()
  if state.fatalStorage then
    state.storageError='Arquivo de bloqueio/vinculo requer revisao; original preservado'
    return
  end
  if not state.lockDirty then return end
  local ok,err=pcall(atomicJSON,LOCK,{version=3,reason=state.reason,utc=os.epoch('utc'),reactor=adapter.name})
  state.storageError=not ok and ('Falha ao salvar bloqueio: '..tostring(err)) or nil
  if ok then state.lockDirty=false end
end
local function sample()
  local ok,d,reason=pcall(function() return adapter:snapshot() end)
  if not ok then state.data=nil trip('FALHA DE LEITURA: '..tostring(d)) return false end
  if not d then state.lastError=reason return false end -- watchdog bounds inconsistent snapshots
  local now,utc=os.clock(),os.epoch('utc')
  if state.freshAt and (now<state.freshAt or utc<state.freshUTC) then
    state.data=nil trip('RELOGIO RETROCEDEU') return false
  end
  state.data,state.freshAt,state.freshUTC,state.lastRead=d,d.readStarted,d.readUTC,d.readSeconds
  local reasonFault=engine:step(d,now,utc)
  if reasonFault then trip(reasonFault) end
  if state.blocked then stopBound() end
  local logged,err=pcall(logResult,engine:status())
  if not logged then trip('FALHA AO SALVAR TESTE: '..tostring(err)) end
  return true
end
local function clearFault()
  assert(not state.fatalStorage,'Corrija o arquivo de bloqueio/vinculo antes de liberar')
  assert(not state.busy,'Operacao em andamento')
  state.busy=true
  local ok,err=pcall(function()
    assert(sample() and nowFresh(),'Sem leitura confiavel para liberar')
    local why=startMargin(state.data) assert(not why,why)
    assert(not state.storageError,state.storageError)
    -- Successful disk operation is required before unlocking.
    atomicJSON(LOCK,{version=3,reason='DESLIGADO; LIBERACAO MANUAL',utc=os.epoch('utc'),reactor=adapter.name})
    fs.delete(LOCK)
    engine:resetAfterFault()
    state.blocked,state.initial,state.reason,state.lastError=false,false,nil,nil
    state.confirmed,state.lockDirty=false,false
    state.generation=state.generation+1
  end)
  state.busy=false
  if not ok then state.lastError='Liberacao recusada: '..tostring(err) error(state.lastError,0) end
end
local function armTest()
  assert(not state.blocked,'Libere o bloqueio com o reator desligado')
  assert(nowFresh(),'Leitura vencida')
  engine:startTest()
end
local function act(cmd,value)
  if cmd=='scram' or (cmd=='setStatus' and value==false) then trip('SCRAM MANUAL') return end
  if cmd=='clearFault' then clearFault() return end
  if cmd=='cancelTest' then
    engine:cancelTest('TESTE CANCELADO PELO USUARIO')
    trip('TESTE CANCELADO PELO USUARIO')
    local ok,err=pcall(logResult,engine:status()) if not ok then state.storageError=tostring(err) end
    return
  end
  assert(not state.blocked,'Controlador bloqueado; libere com o reator desligado')
  assert(nowFresh(),'Sem leitura atual para executar comando')
  if cmd=='startTest' then armTest() return end
  assert(not state.busy,'Operacao em andamento')
  state.busy=true
  local generation=state.generation
  local ok,err=pcall(function()
    local function allowed() return not state.blocked and state.generation==generation end
    assert(sample() and nowFresh(),'Sem leitura nova antes do comando')
    assert(allowed(),'Operacao interrompida por protecao')
    if cmd=='setBurnRate' then adapter:setBurnRate(value,allowed)
    elseif cmd=='setStatus' and value==true then
      local why=startMargin(state.data) assert(not why,why)
      adapter:activate(allowed)
    else error('Comando invalido',0) end
    assert(not state.blocked and state.generation==generation,'Operacao interrompida por protecao')
    sample()
    assert(not state.blocked,'Operacao interrompida por protecao')
  end)
  state.busy=false
  if not ok then
    if state.blocked or state.generation~=generation then stopBound() end
    error(tostring(err),0)
  end
end
local function sampler()
  while true do
    if not state.busy then sample() end
    persist()
    pause(config.POLL_SECONDS)
  end
end
local function watchdog()
  local bootAt=os.clock()
  while true do
    local now,utc=os.clock(),os.epoch('utc')
    if state.freshAt then
      if now<state.freshAt or utc<state.freshUTC or now-state.freshAt>config.MAX_SAMPLE_GAP or
        utc-state.freshUTC>config.MAX_SAMPLE_GAP*1000 then
        trip('INTERVALO SEM LEITURAS: limite '..config.MAX_SAMPLE_GAP..'s')
      end
    elseif now-bootAt>config.BOOT_GRACE_SECONDS then trip('SEM LEITURA NA INICIALIZACAO') end
    if state.blocked then stopBound() end
    pause(.25)
  end
end
local function listener()
  local lastCommand=0
  while true do
    local event,a,channel,_,msg=os.pullEventRaw()
    if event=='terminate' then trip('ENCERRAMENTO SOLICITADO (CTRL+T)')
    elseif event=='key' then
      local ok,err=true,nil
      if a==keys.s then trip('SCRAM MANUAL')
      elseif a==keys.u then ok,err=pcall(clearFault)
      elseif a==keys.t then ok,err=pcall(armTest) end
      if not ok then state.lastError=tostring(err) end
    elseif event=='peripheral_detach' and a==adapter.name then trip('ADAPTADOR DESCONECTADO')
    elseif event=='peripheral' then pcall(openModems)
    elseif event=='modem_message' and channel==config.MODEM_CHANNEL and type(msg)=='table' and
      msg.type=='fission_command_v3' and msg.protocol==3 and integer(config.PANEL_ID) and
      integer(msg.source) and msg.source==config.PANEL_ID and
      msg.target==ID and msg.session==session and integer(msg.id) and msg.id>lastCommand and
      finite(msg.utc) and msg.utc<=os.epoch('utc')+1000 and
      os.epoch('utc')-msg.utc<=config.COMMAND_TIMEOUT_SECONDS*1000 then
      lastCommand=msg.id
      local ok,err=pcall(act,msg.cmd,msg.value)
      if not ok then state.lastError=tostring(err) end
      transmit({type='fission_ack_v3',protocol=3,source=ID,target=msg.source,session=session,id=msg.id,
        ok=ok,reason=not ok and tostring(err) or 'Comando confirmado'})
      publish()
    end
  end
end
-- Emergency events must have their own consumer: listener() may be awaiting
-- a yielded command and cannot be relied on to receive Ctrl+T/S/detach then.
local function emergencyEvents()
  while true do
    local event,id=os.pullEventRaw()
    if event=='terminate' then trip('ENCERRAMENTO SOLICITADO (CTRL+T)')
    elseif event=='key' and id==keys.s then trip('SCRAM MANUAL')
    elseif event=='peripheral_detach' and id==adapter.name then trip('ADAPTADOR DESCONECTADO') end
  end
end
local function telemetry()
  while true do publish() pause(config.TELEMETRY_SECONDS) end
end
local function run()
  config=dofile(fs.combine(DIR,'config.lua'))
  assert(type(config)=='table','Configuracao invalida')
  if args[1] then config.PANEL_ID=tonumber(args[1]) end
  assert(config.PANEL_ID==nil or integer(config.PANEL_ID),'PANEL_ID invalido')
  for _,k in ipairs({'MODEM_CHANNEL','UI_REFRESH','POLL_SECONDS','TELEMETRY_SECONDS','MAX_SAMPLE_GAP','BOOT_GRACE_SECONDS','COMMAND_TIMEOUT_SECONDS'}) do
    assert(finite(config[k]) and config[k]>0,'Configuracao invalida: '..k)
  end
  assert(config.MODEM_CHANNEL<65536 and config.MODEM_CHANNEL%1==0,'Canal invalido')
  local Adapter=dofile(fs.combine(DIR,'functions.lua'))
  local Core=dofile(fs.combine(DIR,'test_logic.lua'))
  state={blocked=true,initial=true,reason='INICIALIZACAO: REVISE E LIBERE DESLIGADO',
    confirmed=false,generation=1,sequence=0,lockDirty=true}
  for _,path in ipairs({LOCK,BINDING}) do
    if fs.exists(path..'.pending') then state.fatalStorage=true state.initial=false state.reason='GRAVACAO INTERROMPIDA: '..path end
  end
  if fs.exists(LOCK) then
    local ok,stored=pcall(readJSON,LOCK)
    if ok and type(stored.reason)=='string' then state.reason=stored.reason state.initial=false
    else state.fatalStorage=true state.initial=false state.reason='BLOQUEIO ILEGIVEL' end
  end
  if fs.exists(BINDING) then
    local ok,stored=pcall(readJSON,BINDING)
    if not ok or type(stored.reactor)~='string' then
      state.fatalStorage=true state.initial=false state.reason='VINCULO ILEGIVEL'
    else
      if config.REACTOR_NAME and config.REACTOR_NAME~=stored.reactor then
        state.fatalStorage=true state.initial=false state.reason='ADAPTADOR DIFERE DO VINCULO SALVO'
      end
      config.REACTOR_NAME=stored.reactor
    end
  end
  adapter=Adapter.new(config)
  adapter:bind()
  engine=Core.new(config)
  stopBound()
  if not fs.exists(BINDING) and not state.fatalStorage then atomicJSON(BINDING,{reactor=adapter.name,version=3}) end
  persist()
  pcall(openModems)
  assert(parallel and parallel.waitForAny,'CC:Tweaked parallel necessario')
  parallel.waitForAny(sampler,watchdog,emergencyEvents,listener,telemetry)
  error('Rotina de supervisao encerrada inesperadamente',0)
end
local ok,err=xpcall(run,function(e) return tostring(e) end)
if not ok then
  local recoverySequence=state and state.sequence or 0
  while true do
    local stopped=emergencyStop(adapter and adapter.name or nil)
    if not fs.exists(LOCK) and not fs.exists(LOCK..'.pending') then
      pcall(atomicJSON,LOCK,{version=3,reason='ERRO INTERNO: '..err,utc=os.epoch('utc')})
    end
    pcall(function()
      local f=assert(fs.open('/fission_error_v3.txt','w')) f.write(err) f.close()
      term.setBackgroundColor(colors.black) term.setTextColor(colors.red) term.clear() term.setCursorPos(1,1)
      print('ERRO INTERNO: '..err) print(stopped and 'SCRAM CONFIRMADO' or 'SCRAM NAO CONFIRMADO')
    end)
    if config then pcall(function()
      recoverySequence=recoverySequence+1
      local seq=recoverySequence
      transmit({type='fission_data_v3',protocol=3,source=ID,session=session,sequence=seq,utc=os.epoch('utc'),
        safety={blocked=true,reason='ERRO INTERNO: '..err,scramConfirmed=stopped},
        test={state='FAILED',reason='ERRO INTERNO',elapsed=0,settle=0,duration=600}})
    end) end
    pause(1)
  end
end
