-- Runs the real UI with CC-style cooperative event fan-out and no real controls.
local path='minecraft/mekanism/fission/reactor.lua'
local hostLoad=loadfile
local function clone(v)
  if type(v)~='table' then return v end
  local t={} for k,x in pairs(v) do t[k]=clone(x) end return t
end
local function harness(options)
  options=options or {}
  local h={now=0,utc=1000000,timers={},timerID=0,sent={},prints={},id=7}
  local e=setmetatable({}, {__index=_G})
  local names={'black','white','blue','pink','lightGray','gray','lightBlue','brown','orange',
    'yellow','magenta','lime','red','green','cyan'}
  e.colors={} for i,name in ipairs(names) do e.colors[name]=2^(i-1) end
  h.colors=e.colors
  local function screen(width,height,monitor)
    local out={w=width,h=height,cx=1,cy=1,bg=e.colors.black,fg=e.colors.white,cells={},backgrounds={}}
    for y=1,height do out.cells[y]={};out.backgrounds[y]={} end
    out.getSize=function()
      if monitor and h.stallDraw then
        repeat local ev=coroutine.yield('monitor_result') until ev=='monitor_result'
        h.stallDraw=false
      end
      if monitor and h.breakUI then error('monitor broken') end
      return width,height
    end
    out.setCursorPos=function(x,y) assert(x>=1 and y>=1 and x<=width and y<=height) out.cx,out.cy=x,y end
    out.setTextColor=function(v) out.fg=v end
    out.setBackgroundColor=function(v) out.bg=v end
    out.setTextScale=function() end
    out.setPaletteColor=function() end
    out.write=function(s)
      for i=1,#s do
        local x=out.cx+i-1
        assert(x<=width,'write exceeds output width')
        out.cells[out.cy][x]=s:sub(i,i);out.backgrounds[out.cy][x]=out.bg
      end
    end
    function out:row(y)
      local text={} for x=1,width do text[x]=self.cells[y][x] or ' ' end
      return table.concat(text)
    end
    function out:text()
      local rows={} for y=1,height do rows[y]=self:row(y) end return table.concat(rows,'\n')
    end
    return out
  end
  h.term=screen(options.termWidth or 80,options.termHeight or 32)
  h.monitor=screen(options.width or 160,options.height or 80,true)
  e.term=h.term
  e.print=function(s) h.prints[#h.prints+1]=tostring(s) end
  e.require=function(name)
    assert(name=='config')
    local controller=17 if options.noSource then controller=nil end
    return {CONTROLLER_ID=controller,MODEM_CHANNEL=43,
      UI_REFRESH=.5,TELEMETRY_STALE_SECONDS=5,PACKET_MAX_AGE_SECONDS=8,COMMAND_TIMEOUT_SECONDS=8,BURN_STEP=.5,
      MAX_SAMPLE_GAP=options.sensorMax}
  end
  e.os={clock=function() return h.now end,epoch=function() return h.utc end,
    getComputerID=function() return h.id end,
    pullEventRaw=function(filter) return coroutine.yield(filter) end,
    startTimer=function(seconds)
      h.timerID=h.timerID+1;h.timers[h.timerID]=h.now+seconds;return h.timerID
    end}
  local modem={open=function(ch) assert(ch==43) end,
    transmit=function(ch,reply,p) assert(ch==43 and reply==43) h.sent[#h.sent+1]=clone(p) end}
  e.peripheral={find=function(kind) if kind=='modem' then return modem end end,
    getNames=function() return {'monitor_0','modem_0'} end,
    getType=function(name) return name=='monitor_0' and 'monitor' or 'modem' end,
    wrap=function(name) return name=='monitor_0' and h.monitor or modem end}
  e.parallel={waitForAny=function(...)
    local cs,filters={},{}
    for i,fn in ipairs({...}) do
      cs[i]=coroutine.create(fn)
      local success,filter=coroutine.resume(cs[i]);assert(success,filter)
      filters[i]=filter
      if coroutine.status(cs[i])=='dead' then return i end
    end
    while true do
      local ev=table.pack(coroutine.yield())
      for i,co in ipairs(cs) do
        if not filters[i] or filters[i]==ev[1] or ev[1]=='terminate' then
          local success,filter=coroutine.resume(co,table.unpack(ev,1,ev.n));assert(success,filter)
          filters[i]=filter
          if coroutine.status(co)=='dead' then return i end
        end
      end
    end
  end}
  function h:boot()
    self.co=coroutine.create(assert(hostLoad(path,'t',e)))
    local success,err=coroutine.resume(self.co,options.argument);assert(success,err)
  end
  function h:event(...)
    assert(coroutine.status(self.co)~='dead','UI already ended')
    local success,err=coroutine.resume(self.co,...);assert(success,err)
  end
  function h:advance(seconds)
    local target=self.now+seconds
    while true do
      local nextID,nextTime
      for id,due in pairs(self.timers) do if due<=target and (not nextTime or due<nextTime) then nextID,nextTime=id,due end end
      if not nextID then break end
      self.utc=self.utc+(nextTime-self.now)*1000;self.now=nextTime;self.timers[nextID]=nil
      self:event('timer',nextID)
    end
    self.utc=self.utc+(target-self.now)*1000;self.now=target
  end
  function h:packet(changes)
    local p={type='fission_data_v3',protocol=3,source=17,session='session-1',sequence=1,utc=self.utc,
      data={active=false,dmg=0,temp=373.15,heatRate=500,br=.5,actual=0,brMax=1920,
        brPct=.5/1920*100,fuelPct=100,wastePct=0,coolPct=51.821,hotPct=0},
      safety={blocked=false,scramConfirmed=false,readSeconds=.2,ageSeconds=.1},
      test={state='IDLE',settle=0,elapsed=0,duration=600}}
    for k,v in pairs(changes or {}) do p[k]=v end
    return p
  end
  function h:receive(p) self:event('modem_message','modem_0',43,43,clone(p)) end
  function h:click(id)
    local w,height=self.monitor.w,self.monitor.h
    local rightW=math.max(15,math.floor(w*.23))
    if w-rightW<25 then rightW=math.max(12,w-25) end
    if w<30 then rightW=math.max(10,math.floor(w*.45)) end
    local leftW=math.max(1,w-rightW-1);rightW=w-leftW-1
    local rightX,topH=leftW+2,math.floor(height/2)
    local x,y=rightX+1,1
    if id=='inc' then x,y=rightX+math.floor(rightW/2)+1,height
    elseif id=='dec' then x,y=rightX+1,height
    elseif id=='test' then y=topH-1
    elseif id=='release' then y=topH end
    self:event('monitor_touch','monitor_0',x,y)
  end
  function h:ack(ok,reason,id)
    local command=self.sent[#self.sent]
    self:receive({type='fission_ack_v3',protocol=3,source=17,target=self.id,session='session-1',
      id=id or command.id,ok=ok,reason=reason})
  end
  return h
end
local total=0
local function test(name,fn)
  local ok,err=pcall(fn);assert(ok,name..': '..tostring(err))
  total=total+1; print('OK '..name)
end
test('original four bars and right controls remain; Celsius only',function()
  local h=harness();h:boot();h:receive(h:packet());h:advance(.5)
  local text=h.monitor:text()
  for _,label in ipairs({'Coolant','Fuel','Heated Coolant','Waste','Burn Rate','OFFLINE','Temp: 100.00 C','TESTAR TAXA'}) do
    assert(text:find(label,1,true),label)
  end
  assert(h.monitor.backgrounds[4][1]==h.colors.lightBlue)
  assert(h.monitor.backgrounds[24][1]==h.colors.gray)
  assert(h.monitor.backgrounds[1][125]==h.colors.red)
  assert(not text:find('Safety Mode',1,true))
end)
test('step is .5 independent of reactor maximum; duplicate click waits for confirmation',function()
  local h=harness();h:boot();h:receive(h:packet());h:advance(.5)
  h:click('inc');h:click('inc')
  assert(#h.sent==1 and h.sent[1].value==1 and h.sent[1].cmd=='setBurnRate')
  assert(h.sent[1].type=='fission_command_v3' and h.sent[1].target==17 and h.sent[1].source==7)
  h:ack(true)
  h:click('inc');assert(#h.sent==1,'ACK alone must not authorize repeated increase')
  local p=h:packet({sequence=2});p.data.br=1;p.data.brPct=1/1920*100
  h:receive(p);h:click('inc')
  assert(#h.sent==2 and h.sent[2].value==1.5)
end)
test('stale telemetry hides old operating state and resources',function()
  local h=harness();h:boot();local p=h:packet();p.data.active=true;p.data.actual=.5
  h:receive(p);h:advance(.5);assert(h.monitor:text():find('ONLINE',1,true))
  h:advance(5)
  local text=h.monitor:text()
  assert(text:find('SEM TELEMETRIA ATUAL',1,true) and text:find('SEM DADOS',1,true))
  assert(not text:find('ONLINE',1,true) and text:find('SEM LEITURA',1,true))
  h:click('inc');assert(#h.sent==0)
end)
test('selected source and complete finite sensor values are required',function()
  local h=harness();h:boot()
  local p=h:packet({source=99});h:receive(p);h:advance(.5)
  assert(h.monitor:text():find('SEM TELEMETRIA ATUAL',1,true))
  p=h:packet();p.data.temp=0/0;h:receive(p);h:advance(.5)
  assert(h.monitor:text():find('SEM DADOS',1,true))
  p=h:packet();p.safety.ageSeconds=nil;h:receive(p);h:advance(.5)
  assert(h.monitor:text():find('SEM DADOS',1,true))
  h:receive(h:packet());h:advance(.5)
  assert(h.monitor:text():find('100.00 C',1,true))
end)
test('sensor age prevents current packet timestamp disguising old data',function()
  local h=harness();h:boot();local p=h:packet();p.safety.ageSeconds=10
  h:receive(p);h:advance(.5)
  assert(h.monitor:text():find('SEM LEITURA CONFIAVEL',1,true))
  assert(not h.monitor:text():find('OFFLINE',1,true))
end)
test('sensor freshness adds time since receipt and honors controller gap limit',function()
  local h=harness({sensorMax=3});h:boot();local p=h:packet();p.safety.ageSeconds=2
  h:receive(p);h:advance(.5)
  assert(h.monitor:text():find('OFFLINE',1,true),'sensor age 2.5 seconds should remain current')
  h:advance(1)
  local text=h.monitor:text()
  assert(text:find('SEM LEITURA CONFIAVEL',1,true),'sensor age must include elapsed time after receipt')
  assert(not text:find('OFFLINE',1,true))
  h:click('inc');assert(#h.sent==0)
end)
test('rejected command displays reason and does not change measured rate',function()
  local h=harness();h:boot();h:receive(h:packet());h:advance(.5)
  h:click('inc');h:ack(false,'Taxa acima do limite');h:advance(.5)
  assert(h.monitor:text():find('RECUSADO: Taxa acima do limite',1,true))
  assert(h.monitor:text():find('0.50/1920 mB/t',1,true))
end)
test('test button only arms evaluation and blocked reactor has separate release',function()
  local h=harness();h:boot();local p=h:packet();p.safety.blocked=true;p.safety.reason='Revisao manual';p.safety.scramConfirmed=true
  h:receive(p);h:advance(.5)
  h:click('onoff');assert(h.sent[1].cmd=='scram')
  h:ack(true);p.sequence=2;h:receive(p)
  h:click('release');assert(h.sent[2].cmd=='clearFault')
  h:ack(true);p.sequence=3;p.safety.blocked=false;h:receive(p)
  h:click('test');assert(h.sent[3].cmd=='startTest' and h.sent[3].value==nil)
end)
test('cancel test requests shutdown and SCRAM bypasses a pending increase',function()
  local h=harness();h:boot();local p=h:packet();p.data.active=true;p.data.actual=.5;p.test.state='MEASURING'
  h:receive(p);h:advance(.5);h:click('test')
  assert(h.sent[1].cmd=='cancelTest')
  h:click('onoff');assert(h.sent[2].cmd=='scram' and h.sent[2].id>h.sent[1].id)
end)
test('source selection instructions include local panel ID',function()
  local h=harness({noSource=true});h:boot();h:receive(h:packet());h:advance(.5)
  assert(h.monitor:text():find('Execute reactor <ID do reator> | ID deste painel: 7',1,true))
  h:click('inc');assert(#h.sent==0)
end)
test('network listener remains live during yielding monitor drawing',function()
  local h=harness();h:boot();h:receive(h:packet());h:advance(.5)
  h.stallDraw=true;h:advance(.5)
  local p=h:packet({sequence=2});p.data.temp=383.15
  h:receive(p)
  h:event('monitor_result');h:advance(.5)
  assert(h.monitor:text():find('110.00 C',1,true))
end)
test('small terminal geometry clips safely and Ctrl T sends no reactor command',function()
  local h=harness({width=51,height=19,termWidth=26,termHeight=12});h:boot();h:receive(h:packet());h:advance(.5)
  h:event('terminate')
  assert(coroutine.status(h.co)=='dead' and #h.sent==0)
end)
test('test progress and changed safety state redraw without numeric sensor changes',function()
  local h=harness();h:boot();h:receive(h:packet());h:advance(.5)
  local p=h:packet({sequence=2});p.test.state='MEASURING';p.test.elapsed=125
  h:receive(p);h:advance(.5)
  assert(h.monitor:text():find('MEDINDO',1,true) and h.monitor:text():find('02:05/10:00',1,true))
  p=h:packet({sequence=3});p.safety.blocked=true;p.safety.reason='FALHA DE LEITURA';p.safety.scramConfirmed=true;p.test.state='FAILED'
  h:receive(p);h:advance(.5)
  assert(h.monitor:text():find('FALHA DE LEITURA',1,true) and h.monitor:text():find('SCRAM CONFIRMADO',1,true))
end)
print(total..' UI scenarios passed')
