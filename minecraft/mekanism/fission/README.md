# FissionReactor-CC: Celsius e teste de estabilidade

Adaptação do [FissionReactor-CC de MohammedMMC](https://github.com/MohammedMMC/FissionReactor-CC), mantendo o layout: **quatro barras de recursos à esquerda e controles à direita**. Temperatura em **Celsius**, botões de queima em passos de **0,5 mB/t** e um teste da taxa escolhida. A origem e a licença GPLv3 estão em [UPSTREAM.md](UPSTREAM.md) e [LICENSE](LICENSE).

O **computador do reator** lê os sensores, avalia a operação, registra o teste e solicita SCRAM. O **computador do painel** exibe os dados e envia apenas ações manuais. Fechar o painel não desliga a proteção local. O programa não aumenta a queima, não liga e não religa o reator automaticamente.

**O teste não provoca dano para descobrir o limite.** Ele observa equilíbrio e solicita desligamento diante de limites de risco ou falta de evidência confiável. APROVADO significa estável no período observado, não ausência garantida de dano ou explosões. Faça o primeiro ensaio numa cópia do mundo, acompanhado; a validação com periféricos simulados não substitui a integração no Minecraft.

## Instalar sem substituir a versão anterior

1. Desligue o reator manualmente. Mantenha o resfriamento e a extração funcionando. Encerre os programas antigos antes de executar os novos; use somente um controlador para o mesmo reator.
2. Em **cada computador**, execute `id` e anote o número. O computador do reator precisa do ID do computador do painel; o computador do painel precisa do ID do computador do reator.
3. Baixe o instalador em cada computador:

```text
wget https://raw.githubusercontent.com/joaocodigoshtmls/GPT/codex/reator-auto-v2/minecraft/mekanism/fission/install.lua /install_fission_v3.lua
```

**No computador do reator**, substitua `ID_DO_PAINEL` pelo número anotado e execute:

```text
/install_fission_v3.lua reactor ID_DO_PAINEL
/fission_v3/reactor-modem.lua
```

**No computador do painel**, substitua `ID_DO_REATOR` pelo número anotado:

```text
/install_fission_v3.lua painel ID_DO_REATOR
/fission_v3/reactor.lua
```

Cada linha é um comando separado. Não digite os nomes `ID_DO_PAINEL` e `ID_DO_REATOR` literalmente.

O instalador baixa todos os arquivos de **um mesmo commit**, verifica a sintaxe Lua e publica a pasta completa em `/fission_v3`. Ele recusa pasta existente e preserva `startup.lua`. Uma instalação incompleta é descartada; um marcador de instalação que já existia é preservado para revisão. Se `/fission_v3` já existir, escolha outra pasta nova:

```text
/install_fission_v3.lua reactor ID_DO_PAINEL /fission_v3_nova
```

Nesse caso, execute o programa a partir da pasta nova. Se `wget` disser `File already exists`, preserve o instalador existente ou baixe a revisão desejada com outro nome; não misture manualmente arquivos de revisões diferentes. `INSTALLED.txt` registra o commit, o papel do computador e o ID configurado.

O instalador consulta a API pública do GitHub uma vez para identificar a revisão. Se essa consulta estiver indisponível ou limitada, é possível fornecer um SHA completo de commit previamente conferido como quarto argumento, após a pasta de destino. Falhas HTTP devem ser investigadas pela mensagem; não é necessário liberar indiscriminadamente a rede do servidor.

## Conferir e testar

No computador do reator, toda inicialização tenta SCRAM e exige revisão manual. O painel mostrará um bloqueio até haver leituras novas, reator desligado, margens adequadas e gravação local funcionando.

1. Confira o ID, as leituras e a confirmação de desligamento. Pressione **U** no computador do reator ou **LIBERAR BLOQUEIO** no painel, com o reator desligado.
2. Escolha a taxa nos botões **− / +** do painel ou na interface do reator. Cada clique altera **0,5 mB/t**, dentro do limite estrutural. A alteração precisa de confirmação; o painel não envia uma sequência de aumentos sem confirmação.
3. Pressione **TESTAR TAXA**. Isso arma a avaliação; não liga o reator e não aumenta a queima.
4. Ligue manualmente pela interface do reator ou pelo botão **ONLINE**, depois de revisar as condições.
5. Acompanhe o estado, a queima real/configurada, as tendências e o motivo de espera. Deixe os programas funcionando durante toda a operação.

| Estado | Significado |
| --- | --- |
| NÃO TESTADO | Proteção ativa; nenhum ensaio armado. |
| AGUARDANDO | Teste armado e reator desligado; não conta tempo. |
| AQUECENDO | Espera equilíbrio da temperatura e dos estoques, incluindo a redistribuição inicial do sódio. |
| ESTABILIZANDO | Confirma equilíbrio contínuo antes da medição. |
| MEDINDO | Mede a taxa exata, com reservas e temperatura sob observação. |
| APROVADO | Estável no período observado; a proteção continua ativa. |
| INTERROMPIDO / BLOQUEADO | Condição adversa, falha de leitura, de gravação ou parada manual; solicita SCRAM. |

O padrão exige janela de tendência de **60 segundos**, **120 segundos de estabilidade** e **600 segundos de medição**: aproximadamente **13 minutos no mínimo**, mais o aquecimento e os intervalos reais de leitura. Falta de equilíbrio por **30 minutos** impede continuar a operação como se fosse estável. Alterar a taxa descarta o progresso e reinicia a avaliação da nova taxa exata, inclusive depois de APROVADO. Não há reutilização automática de uma aprovação antiga.

A queima real precisa corresponder à configurada. Falta de combustível não pode aprovar um ensaio numa taxa menor do que a solicitada. São avaliados temperatura, dano informado pela API, refrigerante frio, refrigerante quente, combustível e resíduos. Além dos percentuais, o teste acompanha **quantidades brutas em mB**, para que um tanque grande não esconda consumo contínuo das reservas.

O aquecimento pode redistribuir o sódio pelo circuito. Essa fase aguarda recuperação/equilíbrio dentro dos limites absolutos, previsões e prazo de observação; não concede aprovação durante uma queda sustentada. Temperatura estável com combustível ou refrigerante diminuindo, ou produtos acumulando, não basta.

O teste distingue consumo contínuo de reposição em ciclos observados. Ciclos só recebem uma faixa de oscilação após retornos repetidos com pisos e tetos estáveis. A faixa fica **fixa** ao começar a medição: ela não acompanha um estoque que vai diminuindo. `TANK_RAW_NOISE = 2` é a tolerância de quantização em mB, não uma autorização para consumir percentuais de um tanque grande. Ciclos longos, instáveis ou pouco observados podem deixar o teste inconclusivo; preserve os dados antes de ajustar a política. Estoques externos grandes ainda podem mascarar falta de capacidade por mais tempo que a medição.

**OFFLINE**, **CANCELAR TESTE** ou **S** no computador do reator solicitam SCRAM e deixam a causa bloqueada para revisão. **T** no computador do reator arma o teste. Ctrl+T no controlador solicita SCRAM e mantém a recuperação; para substituir o programa, desligue o reator manualmente antes de reiniciar o computador. Ctrl+T no computador do painel encerra apenas o painel.

## Limites e temporização

São políticas conservadoras configuráveis em `config.lua`, não limites oficiais universais do Mekanism:

| Medida | Solicita SCRAM | Margem de início/liberação |
| --- | --- | --- |
| Temperatura | A partir de 600 °C | Até 350 °C |
| Dano informado | Qualquer valor acima de zero | Zero |
| Refrigerante frio | Abaixo de 20% | Pelo menos 30% |
| Combustível com reator ativo | Abaixo de 10% | Pelo menos 25% |
| Refrigerante quente | A partir de 85% | Até 50% |
| Resíduos | A partir de 75% | Até 50% |

O [código 1.20.x consultado do Mekanism](https://github.com/mekanism/Mekanism/blob/96c736241e308a9cf1c73f7dcfa9aa221ea559d3/src/generators/java/mekanism/generators/common/content/fission/FissionReactorMultiblockData.java) retorna temperatura em Kelvin; a interface converte para Celsius. O dano percentual é arredondado: **0% na API não comprova ausência de dano microscópico**. O corte de temperatura atua independentemente desse valor. A indicação de aquecimento corresponde a refrigerante aquecido por tick, não a potência térmica.

Leituras independentes são agrupadas para reduzir esperas entre chamadas ao servidor. Estado e taxa são conferidos antes e depois; isso reduz inconsistências, mas não transforma a API num retrato atômico. O tempo real de coleta aparece no painel. A idade considera o início da coleta, de forma conservadora; não é zerada ao terminar uma leitura lenta. O watchdog solicita SCRAM se faltarem leituras confiáveis por mais de **3 segundos**, ou se os relógios usados retrocederem. Esse prazo não assegura proteção suficiente para qualquer taxa: a resposta física do reator e o servidor precisam ser verificados. Não aumente o prazo para ocultar lentidão.

O painel marca dados vencidos como desconhecidos após **5 segundos** sem atualização válida, ou antes se a idade acumulada dos sensores atingir o prazo de **3 segundos** do controlador. Ele seleciona o ID do controlador, confere sessão/contadores/horário e aguarda confirmação dos comandos. Comandos vencidos são recusados; somente o ID do painel autorizado pode solicitar mudanças. Outros computadores podem receber as leituras, mas não comandam o reator sem essa autorização configurada. IDs reduzem mistura acidental, mas não são autenticação criptográfica contra outros jogadores.

O protocolo usa canal **43** e tipos `fission_data_v3`, `fission_command_v3` e `fission_ack_v3`, separados dos comandos do projeto original. Mantenha os programas antigos encerrados: receber protocolos separados não torna dois controladores simultâneos uma instalação válida.

## Arquivos locais e recuperação

| Arquivo na raiz do computador do reator | Uso |
| --- | --- |
| `/fission_lock_v3.json` | Bloqueio persistente e motivo de revisão. |
| `/fission_binding_v3.json` | Nome do adaptador escolhido; reconexão procura o mesmo nome. |
| `/fission_results_v3.jsonl` | Resultados locais dos testes; rotaciona para `.old`. |
| `*.tmp` / `*.pending` | Gravação em andamento; pendência na inicialização requer revisão. |

Com nenhum ou vários reatores compatíveis visíveis, configure `REACTOR_NAME` explicitamente antes de executar. O programa não deve trocar silenciosamente para outro reator. Se houver vínculo ilegível, gravação interrompida ou adaptador diferente do vínculo salvo, mantenha o reator desligado, preserve cópias dos arquivos e investigue. Renomear um arquivo de vínculo ou bloqueio para backup é uma ação de manutenção após corrigir a causa; não use isso para contornar uma falha física. Reiniciar ainda exige liberação manual.

Não há envio automático para GitHub, Pastebin ou outro serviço. Para diagnóstico, copie os arquivos locais e anexe-os à conversa. Em mundo local, normalmente ficam em `saves/<mundo>/computercraft/computer/<ID>/`; em servidor, peça os arquivos ao administrador da pasta real do mundo.

Depois de validar a instalação, é possível acrescentar uma chamada ao `startup.lua` existente, preservando seu conteúdo:

```lua
shell.run('/fission_v3/reactor-modem.lua') -- computador do reator
```

No computador do painel, use `shell.run('/fission_v3/reactor.lua')`. Use o caminho real se instalou em outra pasta. O instalador não faz essa alteração. A inicialização do controlador continua solicitando SCRAM e revisão manual.

## Verificação reproduzível

Na raiz do repositório:

```text
luatex --luaonly minecraft/mekanism/fission/tests/test_logic.lua
luatex --luaonly minecraft/mekanism/fission/tests/test_bridge.lua
luatex --luaonly minecraft/mekanism/fission/tests/test_ui.lua
luatex --luaonly minecraft/mekanism/fission/tests/test_install.lua
```

Também é possível usar `lua` (5.3+) no lugar de `luatex --luaonly`. Os testes usam sensores, eventos, arquivos e HTTP substitutos. O harness do controlador agenda chamadas que aguardam resultados e distribui eventos entre corrotinas, para exercitar atrasos, watchdog, comandos pendentes e parada de emergência. A pasta é independente dos programas anteriores em `minecraft/mekanism/`.

O computador precisa permanecer ligado e carregado, assim como o reator, resfriamento e extração. Um adaptador inacessível impede enviar SCRAM; uma pausa do servidor não pode ser corrigida retroativamente. A confirmação exibida depende de uma leitura nova de desligamento. Nenhum teste finito, mesmo aprovado, garante funcionamento indefinido ou ausência de explosões.
