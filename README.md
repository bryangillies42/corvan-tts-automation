# Saved Objects multi-personagem para Tabletop Simulator

Este repositório contém os Saved Objects, runtimes e ferramentas de desenvolvimento para painéis de personagens no **Tabletop Simulator**. A fundação da v0.2.1 separa identidade, estado, interface, regras, artefatos e releases por personagem, permitindo que vários objetos coexistam na mesma mesa e no mesmo repositório sem compartilharem atualização ou estado por acidente.

O primeiro produto é o [Console do Corvan](characters/corvan/README.md). O [Grimório do Spentar](characters/spentar/README.md) está ativo para desenvolvimento e testes na versão `0.1.0`, mas continua tecnicamente bloqueado para publicação até concluir o aceite no TTS.

## Requisitos

- Tabletop Simulator com scripting habilitado.
- Node.js 20 ou mais recente para desenvolvimento e geração dos artefatos.
- PowerShell 7 para o smoke opcional do MoonSharp e para a API local do TTS.
- Acesso do host ao GitHub para usar **Refresh**. O Saved Object leva um runtime seed para continuar funcionando sem rede.

O repositório não possui dependências npm de produção. PDFs de fichas e imagens de referência não são incluídos até serem aprovados para o personagem correspondente.

## Organização

```text
characters/
  registry.json          identidade, versão, canais e política de publicação
  corvan/                fontes do Corvan e documentação específica
  spentar/               Grimório em desenvolvimento, ainda não publicável
assets/                  espelho imutável das URLs legadas do Corvan v0.2.0
shared/                  bootstrap, core e contratos comuns
templates/character/     ponto de partida para um novo personagem
fixtures/characters/     personagens técnicos usados somente nos testes
scripts/                 build, smoke e ferramentas de desenvolvimento
tests/                   testes de contrato, build e compatibilidade
dist/<characterId>/      artefatos gerados; não é fonte manual
```

`characters/registry.json` é a fonte de identidade do monorepo. Cada personagem tem um `id` slug imutável em kebab-case, nome de exibição, versão SemVer, status, diretórios, nomes de artefato, dimensões de UI, marker, versão mínima do bootstrap e políticas de release. O `package.json` descreve as ferramentas do monorepo; ele não decide a versão ou o canal de um produto.

Um runtime final é estático: não usa `load`, `require` nem código Lua dinâmico. O bootstrap e o core compartilhados coordenam ciclo de vida, identidade, handshake, chat seguro, posse por GUID, cache, persistência, health check e rollback. O core expõe ao adaptador APIs fechadas para UI, chat, dados físicos, estado, undo e renderização; cada adaptador implementa seu schema, migrações, eventos, regras e a mecânica específica que usa essas APIs.

O estado persistido é identificado pelo personagem:

```text
characterId
runtimeVersion
core
character
```

Um estado de outro personagem é recusado. Estados legados sem `characterId` só podem passar pelo migrador explícito do Corvan. A identidade também aparece no manifesto, no health check, no `runtimeReady`, nas GM Notes do painel/helper e nos metadados usados para rastrear os dados físicos.

## Desenvolvimento

```powershell
npm test
npm run build
npm run build:character -- --character corvan
npm run build:fixture
npm run character:new -- --id novo-personagem --name "Nome de Exibição"
npm run test:lua
npm run verify:tts-assets -- --saved-object dist/spentar/Spentar_Console.json
```

O build conjunto compila todos os personagens ativos em `dist/<characterId>/`, inclusive enquanto `productionEnabled` estiver desligado para testes. O build individual permite validar apenas um perfil; a permissão de produção é exigida exclusivamente pelo resolvedor de release. `build:fixture` compila fixtures técnicas, mas elas não podem ser selecionadas pelo workflow. `character:new` valida o template, monta o scaffold de forma recuperável e o registra como não publicável; falha se o id ou o diretório já existirem.

O validador comum verifica identidade, SemVer, tag, paths internos, assets, XML estrutural e colisões de nomes/URLs/GUIDs. O perfil escolhe `uiContract: panel-board` quando precisa da moldura e geometria rígidas do Corvan, ou `uiContract: generic` para layouts sem overlay e com estrutura própria. IDs e eventos continuam declarados por personagem.

`test:lua` é o gate local obrigatório antes de uma release: usa no Windows o MoonSharp fornecido pelo TTS para compilar os runtimes/bootstrap, executar fórmulas, simular callbacks, persistência, Refresh, timeout de rede, integridade e rollback. Ele também executa o bootstrap congelado do Saved Object Corvan v0.2.0 contra os artefatos atuais. O CI hospedado não o executa porque a DLL vem da instalação local do TTS.

`verify:tts-assets` deve ser executado no Saved Object de teste construído com o SHA real do commit. A ferramenta exige URLs imutáveis contendo um SHA Git completo de 40 caracteres, HTTP 200, MIME PNG/JPEG/WebP coerente com os magic bytes e dimensões entre 64 e 16384 pixels. Assim, uma URL de branch, uma página HTML retornada pelo GitHub ou uma imagem inválida falha antes da importação no TTS.

## Artefatos e compatibilidade

O Corvan mantém os nomes legados para não quebrar URLs e instalações existentes:

```text
dist/corvan/corvan-runtime.lua
dist/corvan/manifest.json
dist/corvan/Corvan_Duras_Console.json
```

Os dois arquivos em `assets/` permanecem como espelho byte a byte das imagens em `characters/corvan/assets/`. Eles não são a fonte do build novo; existem para que as URLs raw incorporadas em Saved Objects v0.2.0 continuem válidas.

Para novos personagens, os nomes são inequívocos:

```text
<id>-runtime.lua
<id>-manifest.json
<Nome>_Console.json
```

O manifesto continua em `schemaVersion: 1` e acrescenta, de forma compatível, `characterId`, `releaseTag`, `version`, `minBootstrapVersion`, `commitSha`, `runtime` e `previousVersion`. O bootstrap baixa e verifica o manifesto e o runtime antes de aplicar qualquer alteração; se uma etapa falhar, o runtime e o estado anteriores continuam ativos.

Um Saved Object Corvan v0.2.0 deve poder atualizar para v0.2.1 pelo **Refresh**, sem reimportação e sem perder PV/PM gastos, efeitos, preferência, posição, rotação, escala ou GUIDs. O objetivo da v0.2.1 é preparar a separação multi-personagem; ela não muda as regras do Corvan.

## Criar um personagem

1. Execute `npm run character:new -- --id <id> --name "<nome>"`.
2. Preencha o perfil e a entrada correspondente no registry, mantendo `productionEnabled: false` enquanto a ficha, layout, arte, regras e migrações não estiverem revisados.
3. Implemente o adaptador usando somente as APIs do core e defina o schema/migrador do próprio personagem.
4. Adicione uma fixture ou testes de contrato para layout, estado, eventos, isolamento e rollback.
5. Rode os testes, o build individual, o build conjunto e o smoke Lua. Valide manualmente dois painéis na mesma mesa.
6. Só depois de uma revisão real da ficha ative `productionEnabled` e publique a primeira tag do personagem.

O personagem não deve copiar números, poderes, regras, nomes ou assets do Corvan como placeholders. O Spentar serve como primeira implementação real dessa separação, mas não deve ser tratado como publicável enquanto `productionEnabled` permanecer desligado.

## Fixtures

`fixtures/characters/` contém personagens técnicos que exercitam um layout diferente, eventos diferentes e cálculos que não existem no Corvan. Fixtures servem para testes determinísticos, não aparecem no registry publicável e não podem gerar uma GitHub Release. Uma fixture deve provar que dois painéis não compartilham estado, helper, dados físicos, limpeza ou atualização.

## Refresh e releases

As tags são independentes por personagem:

| Produto | Tag | Descoberta do Refresh | Latest global |
| --- | --- | --- | --- |
| Corvan | `vX.Y.Z` | `/releases/latest`, contrato legado | sim, quando estável |
| Outro personagem | `<id>-vX.Y.Z` | lista paginada de releases filtrada pela tag completa | não |
| Pre-release | mesma forma, com prerelease | ignorada por instalações estáveis | não |

O workflow resolve a tag no registry antes de compilar. Tags desconhecidas, perfis desabilitados, fixtures, versões incompatíveis ou tags ambíguas falham antes da publicação. Para cada personagem, `previousVersion` considera somente a release estável anterior daquele personagem. A release é criada como draft, recebe exatamente runtime, manifesto e Saved Object, é baixada e comparada byte a byte ainda como draft, e só então é publicada. O `Latest` global continua apontando para o Corvan legado; releases estáveis de outros personagens usam `--latest=false`.

O bootstrap novo consulta até dez páginas de 100 releases, ignora draft/prerelease e escolhe a maior versão SemVer da tag inteira do próprio personagem. Se a última página estiver cheia, a busca falha de forma segura para não escolher uma lista incompleta. Rate limit, rede, identidade, tag, URL, tamanho, SHA, marker ou health check inválidos preservam o runtime anterior.

A imutabilidade de releases deve continuar habilitada. Uma correção de uma release publicada exige uma nova versão SemVer; não se substituem assets de uma release imutável.

## Ferramenta local do TTS

Com uma mesa aberta e a API de editor externo habilitada, `scripts/tts-dev-api.ps1` preserva as ações `list` e `exec`:

```powershell
# Lista todos os Saved Objects gerenciados por GM Notes/characterId
pwsh -File scripts/tts-dev-api.ps1 -Action list

# Lista somente um personagem
pwsh -File scripts/tts-dev-api.ps1 -Action list -CharacterId corvan

# Executa uma inspeção Lua por GUID
pwsh -File scripts/tts-dev-api.ps1 -Action exec -Guid ABC123 -Lua 'return getBootstrapInfo()'
```

A listagem não depende do nome visível do objeto. Ela lê `characterId` e os metadados das GM Notes; objetos legados do projeto continuam descobríveis pelo identificador do projeto, sem filtro textual por “Corvan”. A ferramenta é somente de desenvolvimento e não é integrada ao Saved Object publicado.

## Documentação específica

- [Corvan — produto legado e comportamento](characters/corvan/README.md)
- [Spentar — grimório em desenvolvimento](characters/spentar/README.md)
- [Roteiro manual multi-personagem da v0.2.1](docs/testing/multi-character-v0.2.1.md)
- [Roteiro de aceite do Spentar v0.1.0](docs/testing/spentar-v0.1.0.md)

## Limitações

- O host do TTS executa scripts e `WebRequest`; é necessário permitir scripting e acesso a `api.github.com`, `github.com` e `raw.githubusercontent.com`.
- O repositório e suas releases precisam ser públicos para que o Refresh baixe assets sem credenciais.
- Sem internet, o objeto usa o runtime seed e não consegue procurar uma atualização ou baixar um asset ausente do cache.
- Firewall, proxy, indisponibilidade do GitHub ou rate limit podem fazer o Refresh falhar; o runtime atual é preservado.
- O TTS compartilha parte do ambiente de scripting da mesa. O isolamento por `characterId`, GUID e GM Notes é obrigatório, mas não substitui testar dois objetos reais juntos.
- A v0.2.1 não é um importador genérico de fichas nem um motor universal de Tormenta 20. Cada personagem continua tendo regras, estado, layout e migrações próprias.
