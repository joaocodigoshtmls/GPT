-- Strict Mekanism 10.4 adapter. Errors remain errors; no missing-value = zero.
local M = {}
local required = {'getStatus','getBurnRate','getActualBurnRate','getTemperature','getDamagePercent',
  'getHeatingRate','getMaxBurnRate','getCoolant','getFuel','getWaste','getHeatedCoolant',
  'getCoolantCapacity','getFuelCapacity','getHeatedCoolantCapacity','getWasteCapacity',
  'getFuelAssemblies','getFuelSurfaceArea','getHeatCapacity','scram','activate','setBurnRate'}
local reads = {'getTemperature','getDamagePercent','getActualBurnRate','getHeatingRate',
  'getMaxBurnRate','getCoolant','getFuel','getWaste','getHeatedCoolant',
  'getCoolantCapacity','getFuelCapacity','getHeatedCoolantCapacity','getWasteCapacity',
  'getFuelAssemblies','getFuelSurfaceArea','getHeatCapacity'}
function M.finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function number(v,name,positive)
  assert(M.finite(v) and v>=0 and (not positive or v>0),'Leitura invalida: '..name)
  return v
end
function M.new(config)
  local self={name=config.REACTOR_NAME}
  local function compatible(p)
    if not p then return false end
    for _,method in ipairs(required) do if type(p[method])~='function' then return false end end
    return true
  end
  function self:bind()
    if self.name then
      assert(peripheral.isPresent(self.name),'Adaptador desconectado: '..self.name)
      self.p=peripheral.wrap(self.name)
      assert(compatible(self.p),'Adaptador incompativel: '..self.name)
      return self.name
    end
    local found={}
    for _,name in ipairs(peripheral.getNames()) do
      if compatible(peripheral.wrap(name)) then found[#found+1]=name end
    end
    assert(#found==1,'Configure REACTOR_NAME: nenhum ou varios reatores compativeis')
    self.name=found[1] -- Never select a different name during reconnect.
    self.p=peripheral.wrap(self.name)
    return self.name
  end
  local function device()
    assert(self.name and peripheral.isPresent(self.name),'Adaptador desconectado')
    local p=assert(peripheral.wrap(self.name),'Adaptador inacessivel')
    assert(compatible(p),'Adaptador incompativel')
    self.p=p return p
  end
  function self:status()
    local p=device()
    local v=p.getStatus()
    assert(type(v)=='boolean','Estado invalido')
    return v
  end
  function self:scram()
    local ok,err=pcall(function()
      local p=device()
      if self:status()~=false then p.scram() end
      assert(self:status()==false,'SCRAM nao confirmado')
    end)
    return ok,not ok and tostring(err) or nil
  end
  function self:snapshot()
    local started,wall=os.clock(),os.epoch('utc')
    local p=device()
    local active,burn=self:status(),number(p.getBurnRate(),'getBurnRate')
    local raw,jobs={},{}
    -- Native calls may each await the server thread. Queue independent reads
    -- together, rather than paying one server tick for every individual field.
    for _,method in ipairs(reads) do
      local key=method
      jobs[#jobs+1]=function() raw[key]=p[key]() end
    end
    if parallel and parallel.waitForAll then parallel.waitForAll(table.unpack(jobs))
    else for _,job in ipairs(jobs) do job() end end
    local d={active=active,burn=burn}
    d.tempC=number(raw.getTemperature,'getTemperature')-273.15
    d.damage=number(raw.getDamagePercent,'getDamagePercent')
    d.actual=number(raw.getActualBurnRate,'getActualBurnRate')
    d.maxBurn=number(raw.getMaxBurnRate,'getMaxBurnRate',true)
    d.heating=number(raw.getHeatingRate,'getHeatingRate')
    assert(d.damage<=100 and d.burn<=d.maxBurn and d.actual<=d.maxBurn,'Leitura fora da faixa')
    assert(type(raw.getCoolant)=='table' and type(raw.getCoolant.name)=='string','Tipo de refrigerante ausente')
    local parts={self.name,raw.getCoolant.name}
    for _,method in ipairs({'getCoolantCapacity','getFuelCapacity','getHeatedCoolantCapacity',
      'getWasteCapacity','getFuelAssemblies','getFuelSurfaceArea','getHeatCapacity','getMaxBurnRate'}) do
      parts[#parts+1]=string.format('%.17g',number(raw[method],method,true))
    end
    for key,method in pairs({coolant='getCoolant',fuel='getFuel',heated='getHeatedCoolant',waste='getWaste'}) do
      local capMethod=({coolant='getCoolantCapacity',fuel='getFuelCapacity',heated='getHeatedCoolantCapacity',waste='getWasteCapacity'})[key]
      local stack=raw[method]
      assert(type(stack)=='table','Tanque invalido: '..method)
      d[key..'Capacity']=number(raw[capMethod],capMethod,true)
      d[key..'Amount']=number(stack.amount,method..'.amount')
      assert(d[key..'Amount']<=d[key..'Capacity'],'Quantidade acima da capacidade: '..method)
      d[key]=d[key..'Amount']/d[key..'Capacity'] -- derive once from raw mB, never from rounded UI
    end
    d.signature=table.concat(parts,'|')
    local finalActive,finalBurn=self:status(),number(p.getBurnRate(),'getBurnRate')
    d.readStarted,d.readUTC=started,wall -- oldest possible sensor timestamp
    d.readSeconds=os.clock()-started
    d.readWallSeconds=(os.epoch('utc')-wall)/1000
    assert(d.readSeconds>=0 and d.readWallSeconds>=0,'Relogio retrocedeu durante leitura')
    assert(d.readSeconds<=config.MAX_SAMPLE_GAP and d.readWallSeconds<=config.MAX_SAMPLE_GAP,
      string.format('Leitura lenta: %.3fs (limite %.3fs)',math.max(d.readSeconds,d.readWallSeconds),config.MAX_SAMPLE_GAP))
    -- Hard limits are checked even if a user changed rate/status mid-snapshot.
    local hard=d.damage>config.DAMAGE_MAX or d.tempC>=config.TEMP_SCRAM_C or
      d.coolant<config.COOLANT_MIN or d.heated>=config.HEATED_MAX or d.waste>=config.WASTE_MAX or
      (d.active and d.fuel<config.FUEL_MIN)
    if (active~=finalActive or math.abs(burn-finalBurn)>1e-6) and not hard then
      return nil,'Estado/taxa mudou durante a leitura'
    end
    return d
  end
  function self:setBurnRate(rate,allowed)
    assert(M.finite(rate) and rate>=0,'Taxa invalida')
    local p=device()
    assert(rate<=number(p.getMaxBurnRate(),'getMaxBurnRate',true),'Taxa acima do limite estrutural')
    assert(math.abs(rate*100-math.floor(rate*100+.5))<1e-6,'Use no maximo duas casas decimais')
    assert(type(allowed)=='function' and allowed(),'Protecao interrompeu ajuste de taxa')
    p.setBurnRate(rate)
    local observed=number(p.getBurnRate(),'getBurnRate')
    assert(math.abs(observed-rate)<=1e-6,'Taxa configurada nao corresponde ao pedido')
  end
  function self:activate(allowed)
    local p=device()
    assert(self:status()==false,'Reator ja esta ligado')
    assert(type(allowed)=='function' and allowed(),'Protecao interrompeu ativacao')
    p.activate()
    assert(self:status()==true,'Ativacao nao confirmada')
  end
  return self
end
return M
