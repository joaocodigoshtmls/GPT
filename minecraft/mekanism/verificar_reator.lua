-- Passive local API inventory. Does not activate, SCRAM or set anything.
-- Run with the reactor OFF, before starting the controller.
local methods = {
  "getStatus", "getBurnRate", "getActualBurnRate", "getTemperature", "getDamagePercent",
  "getCoolantFilledPercentage", "getHeatedCoolantFilledPercentage", "getWasteFilledPercentage",
  "getFuelFilledPercentage", "getHeatingRate", "getMaxBurnRate", "getCoolant",
  "getCoolantCapacity", "getHeatedCoolantCapacity", "getWasteCapacity", "getFuelCapacity",
  "getFuelAssemblies", "getFuelSurfaceArea", "getHeatCapacity",
}
local lines = {"VERIFICACAO PASSIVA / auto-v2.2", "Computador: " .. os.getComputerID(),
  "Ambiente: " .. tostring(_HOST), "UTC: " .. os.epoch("utc"),
  "Adaptador configurado: " .. tostring(settings.get("reator.adapter")),
  "Nao envia comandos. Leituras sequenciais, nao constituem retrato atomico.",
  "Temperatura=Kelvin; niveis=fracao 0..1; burn/actual=mB/t; dano=percentual arredondado."}
local function add(line) lines[#lines+1] = line print(line) end
local names = peripheral.getNames()
table.sort(names)
for _, name in ipairs(names) do
  add("PERIFERICO: " .. name)
  local ok, available = pcall(peripheral.getMethods, name)
  if ok and type(available)=="table" then
    table.sort(available)
    add("Metodos: " .. table.concat(available, ", "))
  end
  local wrapped, p = pcall(peripheral.wrap, name)
  if wrapped and p then
    if type(p.isWireless)=="function" then
      local success, wireless=pcall(p.isWireless)
      add("Modem sem fio: " .. tostring(wireless))
    end
    if type(p.getBurnRate)=="function" or type(p.scram)=="function" then
      local started=os.epoch("utc")
      for _, method in ipairs(methods) do
        local before=os.epoch("utc")
        local success, value=pcall(function()
          assert(type(p[method])=="function", "METODO AUSENTE")
          return p[method]()
        end)
        local serial, result=pcall(textutils.serializeJSON, value)
        add(method .. " = " .. (success and (serial and result or tostring(value)) or "ERRO: " .. tostring(value)) ..
          " | ms=" .. (os.epoch("utc")-before))
      end
      add("Tempo total das leituras (ms): " .. (os.epoch("utc")-started))
    end
  else add("ERRO ao acessar: " .. tostring(p)) end
end
local path="/verificacao_reator.txt"
local f=assert(fs.open(path,"w"),"Nao conseguiu salvar " .. path)
f.write(table.concat(lines,"\n") .. "\n") f.close()
print("Salvo: " .. path)
print("Envie tambem as versoes de Forge, Mekanism/Generators, CC:Tweaked e addons.")
