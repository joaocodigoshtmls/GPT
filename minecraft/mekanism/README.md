# Supervisão do reator de fissão — Mekanism / CC:Tweaked

A implementação atual está em **[fission/](fission/README.md)**: adaptação do [FissionReactor-CC de MohammedMMC](https://github.com/MohammedMMC/FissionReactor-CC), com o layout original de quatro barras e controles à direita, temperatura em Celsius e modo de teste da taxa escolhida.

- **Computador do reator:** `fission/reactor-modem.lua` executa leituras, proteção local, SCRAM e avaliação.
- **Computador do painel:** `fission/reactor.lua` mantém o layout, mostra dados/teste e envia ações manuais confirmadas.
- **Instalação:** `fission/install.lua` instala um pacote completo em pasta nova, sem substituir `startup.lua`.
- **Configuração:** `fission/config.lua` concentra os critérios de observação e os limites.

Siga os **[comandos separados por computador e o procedimento do teste](fission/README.md#instalar-sem-substituir-a-versão-anterior)**. Mantenha o reator desligado durante a instalação e o circuito de resfriamento/extração funcionando.

O teste procura evidência de estabilidade da taxa real, temperatura e estoques. Não provoca dano para descobrir o limite e não garante ausência de explosões. A avaliação inclui volumes reais dos tanques, para não aprovar consumo de uma reserva grande apenas porque o percentual muda pouco. A primeira execução dentro do Minecraft ainda precisa de acompanhamento em uma cópia do mundo.

Os arquivos `reator_seguro.lua`, `reator_core.lua`, `painel_reator.lua` e demais programas na raiz desta pasta pertencem à implementação anterior. A instalação atual e sua documentação estão inteiramente em `fission/`.
