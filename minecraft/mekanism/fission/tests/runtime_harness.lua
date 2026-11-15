-- CC-style event/peripheral scheduler: native calls yield, parallel duplicates events.
local H={}
function H.new(options)
  options=options or {}
  local h={time=0,utc=1000000,active=options.active~=false,rate=.5,actual=.5,tempC=100,
    damage=0,coolant=.8,fuel=1,heated=.1,waste=.1,files=options.files or {},packets={},lines={},
    stops=0,activations=0,timers={},tasks={},timerID=0,taskID=0,taskDelay=options.taskDelay or .05,
    capacity=15360000,present=true,errors={}}
  local env=setmetatable({}, {__index=_G})
  local function await(fn,method)
    h.taskID=h.taskID+1 local id=h.taskID
    h.tasks[id]={due=h.time+(h.delays and h.delays[method] or h.taskDelay),fn=fn,method=method}
    while true do
      local event,taskID,ok,v=coroutine.yield('task_complete')
      if event=='task_complete' and taskID==id then if not ok then error(v,0) end return v end
    end
  end
  local function parallelRun(all,...)
    local co,filters={},{}
    for i,f in ipairs({...}) do co[i]=coroutine.create(f) end
    local args={}
    while true do
      local remaining=0
      for i,c in ipairs(co) do
        if coroutine.status(c)~='dead' then
          if not filters[i] or filters[i]==args[1] or args[1]=='terminate' then
            local ok,filter=coroutine.resume(c,table.unpack(args))
            if not ok then error(filter,0) end
            filters[i]=filter
            if not all and coroutine.status(c)=='dead' then return i end
          end
          if coroutine.status(c)~='dead' then remaining=remaining+1 end
        end
      end
      if remaining==0 then return end
      args={coroutine.yield()}
    end
  end
  env.parallel={waitForAny=function(...) return parallelRun(false,...) end,
    waitForAll=function(...) return parallelRun(true,...) end}
  env.os={clock=function() return h.time end,epoch=function() return h.utc end,
    getComputerID=function() return 1 end,
    startTimer=function(s) h.timerID=h.timerID+1 h.timers[h.timerID]=h.time+s return h.timerID end,
    cancelTimer=function(id) h.timers[id]=nil end,
    pullEventRaw=function(filter) return coroutine.yield(filter) end}
  env.print=function(s) h.lines[#h.lines+1]=tostring(s) end
  env.colors={black=32768,white=1,red=16384}
  env.keys={s=31,u=22,t=20}
  env.term={setBackgroundColor=function() end,setTextColor=function() end,clear=function() end,setCursorPos=function() end}
  env.shell={getRunningProgram=function() return 'minecraft/mekanism/fission/reactor-modem.lua' end}
  env.fs={getDir=function(p) return p:match('^(.*)/') or '' end,combine=function(a,b) return a..'/'..b end,
    exists=function(p) return h.files[p]~=nil end,getSize=function(p) return #(h.files[p] or '') end,
    delete=function(p) if h.diskFail then error('disk failure') end h.files[p]=nil end,
    move=function(a,b) if h.diskFail then error('disk failure') end assert(h.files[a]) h.files[b]=h.files[a] h.files[a]=nil end,
    open=function(p,mode)
      if h.diskFail and mode~='r' then return nil end
      if mode=='r' and not h.files[p] then return nil end
      local value=mode=='a' and h.files[p] or '' value=value or ''
      return {write=function(s) value=value..s end,writeLine=function(s) value=value..s..'\n' end,
        readAll=function() return h.files[p] end,close=function() if mode~='r' then h.files[p]=value end end}
    end}
  local json,id={},0
  local function copy(t)
    if type(t)~='table' then return t end
    local o={} for k,v in pairs(t) do o[k]=copy(v) end return o
  end
  env.textutils={serializeJSON=function(t) id=id+1 json['json-'..id]=copy(t) return 'json-'..id end,
    unserializeJSON=function(s) return copy(json[s]) end}
  local p={}
  local raw={getStatus=function() return h.active end,getBurnRate=function() return h.rate end,
    getActualBurnRate=function() return h.active and h.actual or 0 end,
    getTemperature=function() return h.tempC+273.15 end,getDamagePercent=function() return h.damage end,
    getHeatingRate=function() return 10 end,getMaxBurnRate=function() return 100 end,
    getCoolant=function() return {name='mekanism:sodium',amount=h.coolant*h.capacity} end,
    getFuel=function() return {name='mekanism:fissile_fuel',amount=h.fuel*h.capacity} end,
    getWaste=function() return {name='mekanism:nuclear_waste',amount=h.waste*h.capacity} end,
    getHeatedCoolant=function() return {name='mekanism:superheated_sodium',amount=h.heated*h.capacity} end,
    getCoolantCapacity=function() return h.capacity end,getFuelCapacity=function() return h.capacity end,
    getWasteCapacity=function() return h.capacity end,getHeatedCoolantCapacity=function() return h.capacity end,
    getFuelAssemblies=function() return 100 end,getFuelSurfaceArea=function() return 400 end,
    getHeatCapacity=function() return 100000 end,
    scram=function() h.stops=h.stops+1 if not h.failScram then h.active=false end end,
    activate=function() h.activations=h.activations+1 h.active=true end,
    setBurnRate=function(rate) h.rate=rate end}
  for method,f in pairs(raw) do
    local key,fn=method,f
    p[key]=function(...)
      local params={...}
      return await(function()
        if not h.present then error('disconnected') end
        if h.errors[key] then error(h.errors[key]) end
        if h.beforeTask then h:beforeTask(key) end
        return fn(table.unpack(params))
      end,key)
    end
  end
  local modem={open=function() end,transmit=function(_,_,packet) h.packets[#h.packets+1]=copy(packet) end}
  env.peripheral={getNames=function() return h.present and {'left','top'} or {'top'} end,
    isPresent=function(name) return name=='top' or (name=='left' and h.present) end,
    wrap=function(name) if name=='left' and h.present then return p elseif name=='top' then return modem end end,
    find=function(kind) if kind=='modem' then return modem end end}
  env.dofile=function(path)
    if h.missingModule and path:match(h.missingModule) then error('missing module') end
    local result=assert(loadfile(path,'t',env))()
    if path:match('config.lua$') then
      result.PANEL_ID=2
      if options.config then for k,v in pairs(options.config) do result[k]=v end end
    end
    return result
  end
  function h:boot()
    self.co=coroutine.create(assert(loadfile('minecraft/mekanism/fission/reactor-modem.lua','t',env)))
    local ok,why=coroutine.resume(self.co) assert(ok,why)
  end
  function h:event(...)
    local ok,why=coroutine.resume(self.co,...) assert(ok,why)
  end
  function h:advance(seconds)
    local untilTime=self.time+seconds
    local count=0
    while true do
      local nextAt,eventID,kind=math.huge,nil,nil
      for id,t in pairs(self.timers) do if t<nextAt then nextAt,eventID,kind=t,id,'timer' end end
      for id,t in pairs(self.tasks) do if t.due<nextAt then nextAt,eventID,kind=t.due,id,'task' end end
      if nextAt>untilTime then break end
      local delta=math.max(0,nextAt-self.time) self.time=self.time+delta self.utc=self.utc+delta*1000
      if kind=='timer' then self.timers[eventID]=nil self:event('timer',eventID)
      else local task=self.tasks[eventID] self.tasks[eventID]=nil
        local ok,value=pcall(task.fn) self:event('task_complete',eventID,ok,value)
      end
      count=count+1 assert(count<100000,'scheduler runaway')
    end
    self.utc=self.utc+(untilTime-self.time)*1000 self.time=untilTime
  end
  function h:last(kind)
    for i=#self.packets,1,-1 do if not kind or self.packets[i].type==kind then return self.packets[i] end end
  end
  function h:command(cmd,value,changes)
    self.commandID=(self.commandID or 0)+1
    local last=assert(self:last('fission_data_v3'),'no telemetry')
    local msg={type='fission_command_v3',protocol=3,source=2,target=1,session=last.session,
      id=self.commandID,utc=self.utc,cmd=cmd,value=value}
    for k,v in pairs(changes or {}) do msg[k]=v end
    self:event('modem_message','top',43,43,msg)
  end
  function h:release() self:event('key',22) self:advance(1) end
  function h:read(path) return env.textutils.unserializeJSON(self.files[path]) end
  function h:record(path,value) self.files[path]=env.textutils.serializeJSON(value) end
  h.env,h.device=env,p
  return h
end
return H
