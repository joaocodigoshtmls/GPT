# Controle automático de fissão — Minecraft 1.20.1

Controlador em Lua para Mekanism 10.4 e CC: Tweaked. Você escolhe o **burn rate no próprio reator**. O programa identifica a taxa, verifica a queima real e inicia sozinho o teste de uma taxa ainda não validada. Não exige digitar a taxa no terminal. Não liga o reator, não aumenta a queima e não faz buscas automáticas pelo limite da instalação.

**Esta versão foi verificada com simulações de Lua e periféricos substitutos; ainda não foi executada em um mundo Minecraft. Faça o primeiro ensaio em uma cópia do mundo, acompanhado.** Um teste mede estabilidade durante uma janela finita; não comprova funcionamento indefinido nem impede uma explosão em qualquer circunstância.

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
```

Também funciona com `luatex --luaonly` no lugar de `lua`. O primeiro testa a lógica com relógios e trajetórias de sensores simulados; o segundo executa os programas completos com periféricos, eventos e arquivos substitutos. Não substituem um ensaio de integração no Minecraft.

Referências primárias: [API do Mekanism 10.4](https://mekanism.github.io/computer_data/10.4.0.html), [eventos e relógios do CC: Tweaked](https://tweaked.cc/module/os.html), [periféricos do CC: Tweaked](https://tweaked.cc/module/peripheral.html).
