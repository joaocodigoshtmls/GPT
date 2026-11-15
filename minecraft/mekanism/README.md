# Controle automático de fissão — Minecraft 1.20.1

Controlador em Lua para Mekanism 10.4 e CC: Tweaked. Você escolhe o **burn rate no próprio reator**. O programa identifica a taxa, verifica a queima real e inicia sozinho o teste de uma taxa ainda não validada. Não exige digitar a taxa no terminal. Não liga o reator, não aumenta a queima e não faz buscas automáticas pelo limite da instalação.

**Esta versão foi verificada com simulações de Lua e periféricos substitutos; ainda não foi executada em um mundo Minecraft. Faça o primeiro ensaio em uma cópia do mundo, acompanhado.** Um teste mede estabilidade durante uma janela finita; não comprova funcionamento indefinido nem impede uma explosão em qualquer circunstância.

## Revisão auto-v2.2 e diagnóstico

Corrigida a regressão final com intervalos irregulares: a última leitura da medição agora entra no cálculo mesmo fora da cadência de amostragem. Antes, uma instalação estável podia receber SCRAM ao terminar o teste porque não existia uma janela completa calculável. A política mudou para `auto-v2.2`; referências anteriores precisam de ensaio completo.

Testes interrompidos por bloqueio agora entram no arquivo de resultados, depois da solicitação de SCRAM. A recuperação de erro interno grava `/reator_erro.txt` e tenta transmitir o motivo sem reaproveitar sensores antigos. Controlador e painel usam todos os modems visíveis; o painel desenha em todos os monitores encontrados. Isso evita depender da ordem de descoberta dos modems. Os modems precisam compartilhar uma rede compatível: um modem cabeado sozinho não alcança um computador ligado apenas por rádio.

### Computador do reator: verificar antes de operar

Com o **reator desligado manualmente**, antes de iniciar o controlador, execute em uma pasta nova:

```text
mkdir /reator_v22
cd /reator_v22
wget https://raw.githubusercontent.com/joaocodigoshtmls/GPT/codex/reator-auto-v2/minecraft/mekanism/verificar_reator.lua verificar_reator.lua
verificar_reator
```

A verificação somente lê: lista os periféricos, os métodos disponíveis, os valores e o tempo das chamadas em `/verificacao_reator.txt`. Não liga, não altera a queima e não envia SCRAM. Não a use para substituir o controlador durante operação. Métodos ausentes ou erros precisam ser investigados antes do ensaio. `_HOST` ajuda a identificar o CC:Tweaked; as versões de Forge, Mekanism, Mekanism Generators e addons devem ser consultadas na lista **Mods** ou nos nomes dos arquivos `.jar`. Minecraft 1.20.1 não determina essas versões.

Depois, ainda com o reator desligado:

```text
wget https://raw.githubusercontent.com/joaocodigoshtmls/GPT/codex/reator-auto-v2/minecraft/mekanism/reator_core.lua reator_core.lua
wget https://raw.githubusercontent.com/joaocodigoshtmls/GPT/codex/reator-auto-v2/minecraft/mekanism/reator_seguro.lua reator_seguro.lua
id
reator_seguro
```

Anote o ID exibido. Verifique as leituras e o bloqueio de inicialização; use **U** apenas após revisar as condições. O reator continua dependendo de ativação manual. O programa usa os arquivos de histórico/bloqueio na raiz, inclusive se estiver instalado em outra pasta. Preserve-os; criar uma pasta nova não elimina bloqueios.

### Computador externo: painel e relatório

Em uma pasta nova, substituindo `17` pelo ID anotado:

```text
mkdir /painel_v22
cd /painel_v22
wget https://raw.githubusercontent.com/joaocodigoshtmls/GPT/codex/reator-auto-v2/minecraft/mekanism/painel_reator.lua painel_reator.lua
wget https://raw.githubusercontent.com/joaocodigoshtmls/GPT/codex/reator-auto-v2/minecraft/mekanism/relatorio_reator.lua relatorio_reator.lua
wget https://raw.githubusercontent.com/joaocodigoshtmls/GPT/codex/reator-auto-v2/minecraft/mekanism/enviar_relatorio.lua enviar_relatorio.lua
settings set reator.source 17
painel_reator
```

Para coletar, encerre **somente o painel externo** com Ctrl+T e execute:

```text
relatorio_reator
```

Espere aparecer `Salvo: /relatorio_reator.txt`. Para publicar esse relatório:

```text
enviar_relatorio /relatorio_reator.txt
```

Esse comando envia o arquivo ao Pastebin e mostra os detalhes retornados por HTTP, também salvos em `/envio_reator.txt`. O `pastebin put` incluído no CC:Tweaked 1.20.x pode mostrar apenas `Failed.` ao falhar o POST: essa mensagem sozinha não identifica a causa. Não desabilite restrições HTTP nem troque configurações às cegas. O novo comando não tenta outro serviço automaticamente.

Para publicar a verificação local, baixe `enviar_relatorio.lua` **no computador do reator, antes de iniciar o controlador**, e execute `enviar_relatorio /verificacao_reator.txt`. Ele também aceita explicitamente `/reator_erro.txt`. Cada execução publica somente o arquivo informado; trate os conteúdos e links como públicos.

Se o envio continuar indisponível, em um mundo local os arquivos ficam normalmente em `saves/<mundo>/computercraft/computer/<ID>/`; em servidor, peça ao administrador o arquivo em `<pasta-do-mundo>/computercraft/computer/<ID>/`. Confirme a pasta real do mundo/instância. Copie o arquivo e anexe-o à conversa; não é preciso publicá-lo no Pastebin. Depois da coleta, reinicie o painel com `painel_reator` na pasta em que o instalou.

### O que foi conferido e o que depende do jogo

A documentação [Mekanism 10.4](https://mekanism.github.io/computer_data/10.4.0.html) e o [código 1.20.x consultado](https://github.com/mekanism/Mekanism/blob/96c736241e308a9cf1c73f7dcfa9aa221ea559d3/src/generators/java/mekanism/generators/common/content/fission/FissionReactorMultiblockData.java) confirmam os métodos usados, `getActualBurnRate` distinto de `getBurnRate`, níveis em frações e dano percentual arredondado. O [wrapper de temperatura](https://github.com/mekanism/Mekanism/blob/96c736241e308a9cf1c73f7dcfa9aa221ea559d3/src/main/java/mekanism/common/integration/computer/SpecialComputerMethodWrapper.java) retorna Kelvin; a subtração de 273,15 está correta. `getHeatingRate` é a quantidade de refrigerante aquecida no tick anterior, não uma potência térmica.

As chamadas não marcadas como seguras para execução paralela passam pela thread principal do servidor no [adaptador CC](https://github.com/mekanism/Mekanism/blob/96c736241e308a9cf1c73f7dcfa9aa221ea559d3/src/main/java/mekanism/common/integration/computer/computercraft/CCMethodCaller.java). Várias chamadas sequenciais podem consumir vários ticks, e não formam uma leitura atômica. A comparação de estado/taxa no fim reduz inconsistências, mas não detecta toda mudança intermediária. Os limites de dois segundos continuam conservadores: servidor lento pode causar SCRAM; não os aumente sem medir a latência e rever a proteção.

Foram mantidos 60 s de tendência, 120 s de estabilidade, 600 s de medição e validade de seis horas. A soma de 780 s é um mínimo aproximado, acrescido do tempo entre leituras. Esses tempos são critérios de observação, não parâmetros oficiais de segurança nem uma comprovação de capacidade sustentável. Seis horas limitam a idade da referência; não garantem que as condições permaneçam iguais nesse período. Reservas externas grandes e ciclos mais longos exigem observação adicional. A reconferência e as proteções contínuas continuam obrigatórias. Limites de tendências são estritos e podem rejeitar alimentação em pulsos; não foram afrouxados sem dados da instalação.

Ainda falta confirmar as versões instaladas, a configuração de integração, os métodos visíveis, a topologia dos modems e o comportamento dentro do Minecraft. Os testes simulados não provam ausência de explosões.

## Instalação e primeira execução

1. Desligue o reator no jogo antes de substituir programas. Mantenha funcionando o resfriamento e a extração dos produtos após o desligamento.
2. No computador ligado ao adaptador do reator, crie uma pasta nova e baixe os **dois** arquivos juntos:

```text
mkdir /reator_auto
cd /reator_auto
wget https://raw.githubusercontent.com/joaocodigoshtmls/GPT/codex/reator-auto-v2/minecraft/mekanism/reator_core.lua reator_core.lua
wget https://raw.githubusercontent.com/joaocodigoshtmls/GPT/codex/reator-auto-v2/minecraft/mekanism/reator_seguro.lua reator_seguro.lua
reator_seguro
```

3. Toda inicialização tenta SCRAM antes mesmo de carregar o módulo e o histórico. Na inicialização normal, o controlador fica bloqueado até você revisar as condições e pressionar **U**, com o reator desligado e os tanques dentro das margens de início.
4. Defina o burn rate na interface do reator e ligue-o manualmente. Uma taxa desconhecida começa a avaliação automática. Uma taxa alterada durante o teste descarta o progresso anterior e inicia uma avaliação nova. Uma mudança durante a leitura, sem um retrato consistente do estado, causa bloqueio conservador.
5. Deixe o controlador funcionando durante toda a operação. Ao iniciar esta nova versão, os antigos arquivos de aprovação não são importados.

Use apenas um programa controlador para o mesmo reator. Com vários adaptadores visíveis, escolha explicitamente o nome do periférico antes de iniciar:

```text
settings set reator.adapter fissionReactorLogicAdapter_0
```

Substitua o nome acima pelo nome real do seu adaptador. Com um único reator ele é encontrado automaticamente e sua identificação fica gravada. A reconexão procura o mesmo nome; não troca automaticamente para outro reator. Vários adaptadores sem seleção impedem a inicialização; a parada de emergência inicial tenta desligar os reatores acessíveis.

## Como a avaliação funciona

| Estado | Significado |
| --- | --- |
| AGUARDANDO | Reator desligado; nenhum segundo de teste é contado. |
| ESTABILIZANDO | Taxa desconhecida. Espera tendências estáveis e margens de início. |
| MEDINDO | Faz 600 segundos de medição contínua na taxa real escolhida. |
| REVALIDANDO | Taxa com aprovação recente: reconfere a estabilidade antes de reutilizá-la. |
| APROVADO | Estável nas condições observadas; todas as proteções continuam funcionando. |
| BLOQUEADO | Falha ou condição adversa: solicita SCRAM, verifica o estado e impede liberação automática. |

Primeiro é necessário formar uma janela de tendência de **60 segundos**. Depois são exigidos **120 segundos consecutivos** de tendências estáveis nas janelas curta e longa; para uma taxa nova, seguem-se **600 segundos** de medição. O mínimo usual é, portanto, aproximadamente **13 minutos**; se precisar de mais tempo para equilibrar a temperatura, demora mais. Após 30 minutos sem concluir, o teste é interrompido com SCRAM por falta de evidência de estabilidade.

Uma taxa antiga só é reutilizada após a reconferência (cerca de três minutos com o sistema já estável). O histórico guarda taxas exatas; aprovar 5 mB/t não aprova automaticamente 4 ou 6 mB/t. A validade é de **seis horas desde o ensaio completo**, sem renovação pela simples reutilização. Após expirar, começa outro ensaio completo, sob supervisão contínua.

Cada aprovação exige:

- Queima real igual à configurada, dentro de tolerância numérica de 0,00000001 mB/t.
- Leituras completas, finitas e dentro das faixas esperadas, sem intervalos superiores a dois segundos.
- Tendência de temperatura dentro do limite e variação máxima de 3 °C na etapa de medição.
- Ausência de consumo sustentado das reservas de refrigerante e combustível ou acúmulo de refrigerante quente e resíduo.
- Tendências favoráveis nas janelas de 10 s, 60 s e na medição completa de 600 s.
- Gravação bem-sucedida do resultado e do histórico.

As tendências usam regressão linear com os tempos efetivamente observados, sem depender de percentuais arredondados da tela. As amostras para tendência são guardadas aproximadamente uma vez por segundo, em memória limitada. A leitura de proteção usa um intervalo solicitado de 0,25 s **mais o tempo das chamadas aos periféricos**; não há promessa de quatro retratos completos por segundo. O painel mostra o tempo consumido pela leitura. Gravação e transmissão não são feitas a cada leitura.

## Limites conservadores desta versão

Estão centralizados em `reator_core.lua`. Não são limites oficiais universais do Mekanism; são a política escolhida para este controlador.

| Medida | Proteção durante operação | Margem para início/liberação |
| --- | --- | --- |
| Temperatura | SCRAM a partir de 450 °C | Até 350 °C |
| Dano mostrado pela API | SCRAM com qualquer valor acima de zero | Zero |
| Refrigerante frio | SCRAM abaixo de 25% | Pelo menos 50% |
| Refrigerante quente | SCRAM a partir de 85% | Até 50% |
| Resíduo | SCRAM a partir de 75% | Até 50% |
| Combustível, com reator ativo | SCRAM abaixo de 10% | Pelo menos 25% |
| Intervalo entre retratos completos | SCRAM acima de 2 s ou relógio retrocedendo | Leituras novas |

A previsão conservadora solicita SCRAM se a tendência de 10 s indicar chegada a um desses limites nos próximos 60 s. Na janela de 60 s, perda de refrigerante ou acúmulo de quente/resíduo acima de 0,012 ponto percentual por minuto provoca SCRAM mesmo com temperatura estável.

Para estabilidade, a subida de temperatura deve ser no máximo 0,6 °C/min e a tendência adversa de cada tanque no máximo 0,006 ponto percentual/min. Durante a medição completa, queda de refrigerante/combustível ou aumento de quente/resíduo acima de **0,05 ponto percentual** em relação ao início interrompe o teste. São margens estritas: instalações com alimentação em pulsos podem precisar de análise antes de ajustar a política.

A falta momentânea de queima real admite até cinco segundos apenas na estabilização. Durante a medição ou depois da aprovação, divergência causa SCRAM imediatamente na próxima leitura. A API pode informar dano arredondado; o controle de temperatura atua independentemente desse valor.

## Histórico, bloqueios e recuperação

A assinatura inclui nome do adaptador, tipo de refrigerante, capacidades, quantidade e superfície dos elementos de combustível, capacidade térmica, limite estrutural de queima e a configuração do programa. Alterações observadas de assinatura durante operação provocam SCRAM. Mudanças na tubulação, bombas, energia, boiler, turbina ou configurações externas não são integralmente identificáveis por essa assinatura; **pressione R para invalidar as referências ao modificar a instalação**.

| Arquivo no computador do jogo | Uso |
| --- | --- |
| `/reator_auto_v2.json` | Histórico de até 128 referências recentes e identificação do adaptador. |
| `/reator_scram.json` | Bloqueio persistente; permanece após reiniciar. Compatível com o bloqueio anterior. |
| `/reator_testes_v2.jsonl` | Resultados e estatísticas; rotaciona perto de 512 KB para `.old`. |
| `*.tmp` e `*.pending` | Gravação em andamento; marcador pendente após reiniciar exige revisão. |

Um disparo de segurança invalida as aprovações guardadas. Uma inicialização limpa preserva referências recentes, mas exige liberação manual e reconferência da estabilidade. Histórico ilegível ou gravação interrompida bloqueia a liberação e não deve ser apagado automaticamente pelo controlador.

Se houver falha de arquivo: mantenha o reator desligado, salve uma cópia dos arquivos para diagnóstico, corrija o espaço/permissões e **renomeie** o arquivo ilegível e os marcadores `.pending` correspondentes para nomes de backup. Reinicie o computador. Isso elimina as referências disponíveis; elas precisarão ser medidas novamente. Não remova um bloqueio para operar com uma causa física ainda presente.

**S** solicita SCRAM manual. **U** libera um bloqueio apenas com reator desligado e condições adequadas. **R** invalida as referências e inicia uma avaliação nova da taxa observada. **Ctrl+T** solicita SCRAM e mantém a rotina de desligamento funcionando, repetindo a tentativa caso não consiga confirmar o estado. Não é um comando para sair e deixar o reator funcionando.

Um erro inesperado do programa entra em recuperação e continua tentando desligar o mesmo reator. Falhas de tela e transmissão são isoladas da avaliação. Falhas de leitura e de gravação de resultados causam bloqueio. A confirmação de SCRAM só é exibida após uma leitura nova de `getStatus() == false`.

## Painel remoto

No controlador, execute `id` para obter o ID do computador. Em outro computador com modem e monitor, baixe o novo painel:

```text
wget https://raw.githubusercontent.com/joaocodigoshtmls/GPT/codex/reator-auto-v2/minecraft/mekanism/painel_reator.lua painel_reator.lua
settings set reator.source 17
painel_reator
```

Troque **17** pelo ID real do controlador. Também é possível executar `painel_reator 17`. Configure o mesmo canal (42) nos programas se precisar alterá-lo. O painel anterior não entende o novo protocolo: atualize os dois lados.

O painel mostra taxa configurada/real, temperatura, níveis, tendências por minuto, contadores, tempo da leitura e estimativas de chegada aos limites. Usa páginas em telas menores e cartões em telas grandes. Aceita apenas o ID configurado, valida campos e rejeita mensagens atrasadas/repetidas. Isso reduz mistura acidental de telemetria; não é autenticação criptográfica contra outro jogador.

Após três segundos sem receber mensagens, ou se o pacote tiver cinco segundos de idade, mostra **estado desconhecido**. Perder o painel ou seu modem não equivale a desligar o controlador. O painel é somente leitura e não comanda o reator.

## Inicialização automática

Depois dos ensaios na cópia do mundo, é possível adicionar ao seu `startup.lua` existente:

```lua
shell.run("/reator_auto/reator_seguro.lua")
```

Preserve o restante do seu arquivo de inicialização e use o caminho real onde instalou os programas. Reiniciar sempre exige revisão e U; não há ativação automática do reator.

## Alcance da proteção

O programa não executa enquanto o computador estiver desligado, descarregado, removido ou com o servidor parado. Detectar uma pausa ao retornar não permite agir durante a pausa. Mantenha carregados o controlador, o reator e **todo o circuito** necessário ao resfriamento e à extração. Um adaptador desconectado impede enviar SCRAM ao reator; o programa exibe que não foi confirmado e tenta novamente ao reconectar.

Esta versão lê os tanques **do reator**, não mede diretamente todos os estoques externos ou a capacidade de cada máquina do circuito. Um estoque externo grande pode esconder uma falha por mais tempo do que o teste. Não há como garantir sustentabilidade indefinida ou ausência de explosões apenas por um ensaio local. Mantenha supervisão após APROVADO e repita os testes após alterações.

## Verificação reproduzível

Sem bibliotecas externas, da raiz do repositório:

```bash
lua minecraft/mekanism/tests/test_core.lua
lua minecraft/mekanism/tests/test_runtime.lua
lua minecraft/mekanism/tests/test_report.lua
lua minecraft/mekanism/tests/test_tools.lua
```

Também funciona com `luatex --luaonly` no lugar de `lua`. O primeiro testa a lógica com relógios e trajetórias de sensores simulados; os demais executam os programas com periféricos, eventos, HTTP e arquivos substitutos. Não substituem um ensaio de integração no Minecraft.

Referências primárias: [API do Mekanism 10.4](https://mekanism.github.io/computer_data/10.4.0.html), [eventos e relógios do CC: Tweaked](https://tweaked.cc/module/os.html), [periféricos do CC: Tweaked](https://tweaked.cc/module/peripheral.html).

## Exportar um relatório para fora do jogo

No **computador externo dos monitores**, encerre somente o painel com Ctrl+T. Mantenha o programa de controle no computador do reator funcionando. Baixe e execute o coletor:

```text
wget https://raw.githubusercontent.com/joaocodigoshtmls/GPT/codex/reator-auto-v2/minecraft/mekanism/relatorio_reator.lua relatorio_reator.lua
relatorio_reator
```

Ele escuta a telemetria durante 60 segundos, gera `/relatorio_reator.txt` e mantém o relatório anterior em `.anterior`. Aceita os protocolos V1 e V2; não transmite comandos e não altera o reator. Se `reator.source` estiver configurado no computador, usa esse ID; sem a configuração, registra todos os controladores compatíveis no canal 42. Para escolher ID e duração explicitamente: `relatorio_reator 17 120`.

O arquivo contém versão de protocolo, ID, estados, falhas transmitidas, leituras, progresso, tendências e horários de recepção. Não lê senhas, tokens ou arquivos pessoais. Também registra falta de modem/sinal e IDs diferentes do filtro. O relatório reproduz o que foi transmitido; se o controlador parou antes de transmitir seu erro, o erro interno não estará disponível por essa coleta. Nesse caso, também será necessário ler a mensagem da tela do computador do reator.

Para **publicar o relatório no Pastebin e obter um link**, use o programa incluído no CC: Tweaked:

```text
pastebin put /relatorio_reator.txt
```

Esse último comando envia o conteúdo ao site; trate o link e o conteúdo como públicos. Ele requer HTTP habilitado e acesso ao Pastebin. Se falhar, o relatório continua salvo no computador do jogo; copie a mensagem do erro para investigar o acesso. A coleta não precisa de acesso à internet, apenas da ligação entre os modems.

Depois volte ao painel com `painel_auto 17` (ou o nome real do seu programa), usando o ID correto. Este coletor foi verificado em sete cenários simulados; ainda precisa de ensaio no Minecraft.
