# Console de Combate do Corvan

Painel físico para o Tabletop Simulator que automatiza os ataques, danos, recursos, poderes e perícias de **Corvan Duras** em Tormenta 20. O objeto é importado uma vez e permanece movível e escalável na mesa; novas versões da lógica e da interface podem ser aplicadas pelo botão **Refresh** sem reimportar o painel.

## Requisitos

- Tabletop Simulator com scripting habilitado.
- Node.js 20 ou mais recente apenas para desenvolver e gerar os artefatos.
- Acesso do host ao GitHub para baixar assets e usar o Refresh. O runtime incluído no objeto continua funcionando offline.

O projeto não possui dependências npm. O PDF da ficha e as imagens de referência não fazem parte do repositório.

## Desenvolvimento

```powershell
npm test
npm run build
npm run test:lua
```

`test:lua` é o smoke opcional de Windows (PowerShell 7): usa o MoonSharp instalado junto do próprio TTS para compilar runtime/bootstrap, executar as fórmulas centrais e simular `onLoad`, persistência de cópias, timeout de rede, update e rollback.

O build valida `src/character.json` e `src/ui.xml`, incorpora ambos ao runtime Lua e inclui uma cópia offline do runtime no bootstrap. Os três artefatos determinísticos são escritos em `dist/`:

- `corvan-runtime.lua`: lógica, interface e dados atualizáveis;
- `manifest.json`: metadados, URL, tamanho e SHA-256 do runtime;
- `Corvan_Duras_Console.json`: Saved Object pronto para importar no TTS.

Para identificar uma compilação sem alterar os fontes, defina `CORVAN_COMMIT_SHA` antes do build. Sem essa variável, o manifesto usa um SHA nulo de 40 caracteres como marcador determinístico; releases recebem automaticamente o SHA real da tag.
O workflow de release também descobre a tag estável anterior e a registra em `previousVersion` (na primeira release, o valor é `null`).

Com uma mesa aberta e a API de editor externo do TTS disponível, `scripts/tts-dev-api.ps1` permite listar os objetos do Corvan ou executar uma inspeção Lua por GUID. O script é apenas uma ferramenta de desenvolvimento e não integra o Saved Object publicado.

## Importar uma única vez

1. Baixe `Corvan_Duras_Console.json` na [release mais recente](https://github.com/bryangillies42/corvan-tts-automation/releases/latest).
2. Coloque o arquivo na pasta de Saved Objects do Tabletop Simulator (`Documents/My Games/Tabletop Simulator/Saves/Saved Objects` no Windows).
3. Abra a mesa, acesse **Objects > Saved Objects** e posicione **Corvan Duras Console**.
4. Mova, gire e redimensione o objeto como desejar. Para manter painel, texto e hitboxes alinhados, aplique o mesmo fator de escala aos três eixos, preservando a proporção inicial. Esse mesmo objeto será preservado nas atualizações.

O painel oferece PV/PM ajustáveis por magnitude (digite um valor e use `−` ou `+`), Defesa/RD, seleção de Espada Longa ou Escudo Pesado, rolagens físicas de ataque/dano/crítico, poderes, perícias, fim de turno/cena, desfazer e calibração da posição dos dados. Em **Configurações**, o toggle de gasto automático permite decidir se os poderes devem validar e descontar PV/PM; desligá-lo não interfere nos ajustes manuais. As mensagens de resultado aparecem de forma curta no chat. Uma nova rolagem remove automaticamente os dados anteriores do próprio painel; o botão **Limpar Dados** permite removê-los manualmente sem alterar o resultado ou o estado do personagem.

## Refresh e releases

O bootstrap embutido é estável. Ao acionar **Refresh**, ele consulta o manifesto da release estável mais recente, baixa todo o runtime antes de aplicá-lo e mantém o runtime anterior para rollback. A prancha visível não é recarregada, portanto GUID, posição, rotação e escala permanecem intactos.

A partir da v0.1.7, painéis legados recebem também a moldura nova como uma camada visual da UI. Isso permite atualizar um painel v0.1.6 com o próprio **Refresh**, sem substituir o JSON e sem alterar sua textura física original. Importações novas já usam a moldura como textura física e mantêm essa camada redundante desativada. Se a imagem remota da camada não puder ser carregada, a textura antiga continua visível como fallback.

Uma tag `v*` que corresponda à versão de `package.json` executa testes, gera os artefatos com o SHA do commit, anexa tudo a um draft e só então publica a GitHub Release. A imutabilidade de releases deve estar habilitada nas configurações do repositório; uma correção exige uma nova versão SemVer.

## Limitações do TTS

- Scripts e `WebRequest` são executados pelo host da mesa; ele precisa permitir scripting e conseguir acessar `api.github.com`, `github.com` e `raw.githubusercontent.com`.
- O repositório e suas releases precisam permanecer públicos para que o TTS faça os downloads sem credenciais.
- Sem internet, o painel usa normalmente o runtime seed incluído, mas não consegue procurar atualizações nem carregar um asset ainda ausente do cache local.
- Firewalls, proxies, indisponibilidade do GitHub ou limites da API podem fazer o Refresh falhar. Nesse caso, a versão ativa é preservada.
- O estado e os controles são compartilhados pela mesa; esta primeira versão é específica para Corvan, não um importador genérico de fichas T20.

## Estrutura

```text
src/       bootstrap estável, runtime, XML e dados do personagem
scripts/   build zero-dependency em Node.js
tests/     testes do bundler e dos artefatos
assets/    arte do painel hospedada publicamente
dist/      artefatos gerados (não versionados)
```
