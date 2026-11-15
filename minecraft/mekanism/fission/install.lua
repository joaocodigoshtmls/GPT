-- Install into a NEW directory. Never starts a reactor program or replaces startup.
local roleArg, peerArg, destinationArg, commitArg = ...
local OWNER, REPO, BRANCH = 'joaocodigoshtmls', 'GPT', 'codex/reator-auto-v2'
local PACKAGE = 'minecraft/mekanism/fission/'
local files = {'config.lua','functions.lua','reactor-modem.lua','reactor.lua','test_logic.lua','LICENSE','UPSTREAM.md'}
local staging, stagingCreated
local function ask(prompt)
  write(prompt)
  return read()
end
local function integer(value)
  local n=tonumber(value)
  return n and n>=0 and n<9007199254740992 and n%1==0 and n or nil
end
local function get(url)
  assert(http and type(http.get)=='function','HTTP desabilitado no CC:Tweaked')
  local response,err,failed=http.get(url,{['User-Agent']='FissionReactor-CC installer'})
  if not response then
    if failed then pcall(failed.close) end
    error('Download falhou: '..tostring(err)..'\n'..url,0)
  end
  local ok,body=pcall(function()
    local code=response.getResponseCode()
    assert(code>=200 and code<300,'HTTP '..tostring(code)..': '..url)
    local content=response.readAll()
    assert(type(content)=='string' and #content>0 and #content<=512000,'Download vazio ou grande demais: '..url)
    return content
  end)
  response.close()
  assert(ok,body)
  return body
end
local function writeFile(path,content)
  local f=assert(fs.open(path,'w'),'Nao conseguiu criar '..path)
  local ok,err=pcall(f.write,content)
  f.close()
  assert(ok,err)
end
local function run()
  print('FISSION | instalacao em pasta nova')
  print('Mantenha o reator desligado; resfriamento e extracao devem continuar funcionando.')
  print('Este instalador nao inicia programas e nao modifica startup.lua.')
  local role=roleArg or ask('Computador: 1=reator, 2=painel: ')
  if role=='1' or role=='reator' then role='reactor' end
  if role=='2' then role='painel' end
  assert(role=='reactor' or role=='painel','Use reactor ou painel para escolher o computador')
  local label=role=='reactor' and 'painel' or 'reator'
  local peer=integer(peerArg or ask('ID do computador do '..label..': '))
  assert(peer,'ID deve ser um inteiro nao negativo')
  local destination=destinationArg or '/fission_v3'
  assert(type(destination)=='string' and destination~='' and destination~='/' and destination:sub(-1)~='/',
    'Escolha uma pasta nova, por exemplo /fission_v3')
  if shell and shell.resolve then destination=shell.resolve(destination) end
  assert(not fs.exists(destination),'Pasta ja existe: '..destination..'. Escolha outra pasta; nada foi substituido.')
  staging=destination..'.installing'
  assert(not fs.exists(staging),'Pasta pendente ja existe: '..staging..'. Preserve/revise antes de instalar.')

  -- Resolve once, so all files come from the same commit even if the branch moves.
  local commit=commitArg
  if not commit then
    local url='https://api.github.com/repos/'..OWNER..'/'..REPO..'/git/ref/heads/'..BRANCH
    local ref=textutils.unserializeJSON(get(url))
    assert(type(ref)=='table' and type(ref.object)=='table' and ref.object.type=='commit',
      'Nao conseguiu identificar um commit da branch')
    commit=ref.object.sha
  end
  assert(type(commit)=='string' and #commit==40 and not commit:find('[^%da-fA-F]'),'Commit invalido')
  print('Versao: '..commit:sub(1,12))
  fs.makeDir(staging)
  stagingCreated=true
  local base='https://raw.githubusercontent.com/'..OWNER..'/'..REPO..'/'..commit..'/'..PACKAGE
  for _,name in ipairs(files) do
    print('Baixando '..name)
    local content=get(base..name)
    if name:sub(-4)=='.lua' then
      local chunk,err=load(content,'@'..name,'t',{})
      assert(chunk,'Sintaxe invalida em '..name..': '..tostring(err))
    end
    if name=='config.lua' then
      local field=role=='reactor' and 'PANEL_ID' or 'CONTROLLER_ID'
      local count
      content,count=content:gsub('('..field..'%s*=%s*)nil','%1'..string.format('%.0f',peer),1)
      assert(count==1,'Campo de configuracao ausente: '..field)
    end
    writeFile(fs.combine(staging,name),content)
  end
  writeFile(fs.combine(staging,'INSTALLED.txt'),
    'Commit: '..commit..'\nComputador: '..role..'\nID do par: '..string.format('%.0f',peer)..'\n')
  assert(not fs.exists(destination),'A pasta de destino foi criada durante a instalacao')
  fs.move(staging,destination)
  stagingCreated=false
  local entry=role=='reactor' and 'reactor-modem.lua' or 'reactor.lua'
  print('Instalado em '..destination)
  print('Primeiro encerre o programa antigo deste computador.')
  print('Depois execute:')
  print(fs.combine(destination,entry))
  print('ID deste computador: '..os.getComputerID())
  return destination
end
local ok,result=pcall(run)
if not ok then
  -- Only remove the staging directory created by THIS attempt.
  if stagingCreated and fs.exists(staging) then pcall(fs.delete,staging) end
  error('INSTALACAO CANCELADA: '..tostring(result),0)
end
return result
