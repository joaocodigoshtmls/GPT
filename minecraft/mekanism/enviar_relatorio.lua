-- Explicit upload of one diagnostic file to Pastebin, with HTTP error details.
-- Uses the public application key from CC:Tweaked's bundled pastebin program.
local path=(...) or "/relatorio_reator.txt"
local allowed={["/relatorio_reator.txt"]=true,["/verificacao_reator.txt"]=true,["/reator_erro.txt"]=true}
assert(allowed[path], "Use /relatorio_reator.txt, /verificacao_reator.txt ou /reator_erro.txt")
local lines={}
local function report(s) s=tostring(s) lines[#lines+1]=s print(s) end
local function run()
  assert(http and type(http.post)=="function", "HTTP desabilitado no CC:Tweaked do servidor")
  assert(fs.exists(path) and not fs.isDir(path), "Arquivo nao existe: " .. path)
  local f=assert(fs.open(path,"r")) local body=f.readAll() f.close()
  report("Enviando " .. path .. " ao Pastebin. Conteudo e link devem ser tratados como publicos.")
  local response,err,failed=http.post("https://pastebin.com/api/api_post.php",
    "api_option=paste&api_dev_key=0ec2eb25b6166c0c27a394ae118ad829&api_paste_format=text&api_paste_name=" ..
    textutils.urlEncode(fs.getName(path)) .. "&api_paste_code=" .. textutils.urlEncode(body))
  local handle=response or failed
  local result
  if handle then
    local code,message=handle.getResponseCode()
    report("HTTP: " .. tostring(code) .. " " .. tostring(message))
    result=handle.readAll() handle.close()
  end
  if not response then report("FALHA HTTP: " .. tostring(err)) end
  if result then report("Resposta: " .. result:sub(1,2000)) end
  if response and result and result:match("^https://pastebin%.com/[%w]+%s*$") then
    report("Envio confirmado: " .. result)
  else report("ENVIO NAO CONFIRMADO. Guarde a mensagem acima; o arquivo local foi preservado.") end
end
local ok,err=pcall(run)
if not ok then report("FALHA: " .. tostring(err)) end
local f=fs.open("/envio_reator.txt","w")
if f then f.write(table.concat(lines,"\n") .. "\n") f.close() end
